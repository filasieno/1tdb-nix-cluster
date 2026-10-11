{
  config,
  lib,
  pkgs,
  commands,
  ...
}:
let
  azure = import ../azure.nix;
  cluster = import ../cluster.nix;
  configFile = pkgs.writeText "vault.hcl" ''
    ui = false
    disable_mlock = true
    api_addr = "http://127.0.0.1:8200"

    listener "tcp" {
      address = "127.0.0.1:8200"
      tls_disable = "true"
    }

    listener "tcp" {
      address = "${cluster.lan.address}:8201"
      tls_cert_file = "/var/lib/vault/tls/tls.crt"
      tls_key_file = "/var/lib/vault/tls/tls.key"
      tls_min_version = "tls12"
    }

    storage "file" {
      path = "/var/lib/vault"
    }

    seal "azurekeyvault" {
      vault_name = "${azure.vaultName}"
      key_name = "${azure.keyName}"
    }
  '';
  # The client secret arrives through systemd's credential mechanism:
  # LoadCredentialEncrypted below hands the TPM-sealed file to systemd,
  # which unseals it and exposes the clear text under $CREDENTIALS_DIRECTORY,
  # readable by the vault user only. Trailing newlines are dropped so the
  # value Azure sees is exactly the secret.
  sealed = builtins.pathExists azure.credentialFile;
  vaultServer = pkgs.writeShellScript "vault-server" ''
    set -euo pipefail
    cred="''${CREDENTIALS_DIRECTORY:-/nonexistent}/${azure.credentialName}"
    if [[ ! -r $cred ]]; then
      echo "no Azure client secret: seal it with 'sudo vault-seal-credential', commit secrets/${azure.credentialName}.cred, and switch" >&2
      exit 1
    fi
    export AZURE_TENANT_ID="${azure.tenantId}"
    export AZURE_CLIENT_ID="${azure.clientId}"
    AZURE_CLIENT_SECRET="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$cred")"
    export AZURE_CLIENT_SECRET
    if [[ -z $AZURE_CLIENT_SECRET ]]; then
      echo "Azure client secret is empty" >&2
      exit 1
    fi
    exec ${pkgs.vault}/bin/vault server -config ${configFile}
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/vault 0700 vault vault -"
    "d /var/lib/vault/tls 0750 vault vault -"
  ];

  environment.systemPackages = [ commands.vaultSealCredential ];

  warnings = lib.optional (!sealed) ''
    durin: secrets/${azure.credentialName}.cred is absent. The system builds and boots,
    vault.service fails until the secret is sealed on durin's TPM and committed:
      sops -d --extract '["azure_client_secret"]' nodes/durin/secrets/secrets.yaml \
        | ssh durin sudo vault-seal-credential > nodes/durin/secrets/${azure.credentialName}.cred
  '';

  systemd.services.vault-tls = {
    description = "Vault listener certificate";
    wantedBy = [ "vault.service" ];
    before = [ "vault.service" ];
    after = [
      "systemd-sysusers.service"
      "systemd-tmpfiles-setup.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe commands.vaultTls;
    };
  };

  systemd.services.vault = {
    description = "HashiCorp Vault";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "vault-tls.service"
      "lan1-ready.service"
    ];
    after = [
      "vault-tls.service"
      "network-online.target"
      "lan1-ready.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      User = "vault";
      Group = "vault";
      # Sealed with --with-key=tpm2 and no PCR policy, so it survives
      # firmware and kernel updates and any reinstall on this board.
      LoadCredentialEncrypted = lib.mkIf sealed "${azure.credentialName}:${azure.credentialFile}";
      ExecStart = vaultServer;
      StateDirectory = "vault";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitMEMLOCK = "infinity";
      AmbientCapabilities = "cap_ipc_lock";
      KillSignal = "SIGINT";
      TimeoutStopSec = "30s";
      OOMScoreAdjust = -500;
      MemoryAccounting = true;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };

  systemd.services.vault-init = {
    description = "Initialize Vault once";
    wantedBy = [ "multi-user.target" ];
    after = [
      "vault.service"
      "network-online.target"
    ];
    wants = [
      "vault.service"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = lib.getExe commands.vaultInit;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
