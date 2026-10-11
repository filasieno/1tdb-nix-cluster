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
  # Read the sops files at start and drop a trailing newline. An
  # EnvironmentFile that inlines the secret keeps that newline inside the
  # quotes, systemd rejects the file, and Vault never receives the Azure
  # credentials it needs to unwrap the seal.
  vaultServer = pkgs.writeShellScript "vault-server" ''
    set -euo pipefail
    read_secret() {
      ${pkgs.coreutils}/bin/tr -d '\r\n' < "$1"
    }
    export AZURE_TENANT_ID="$(read_secret "${config.sops.secrets.azure-tenant-id.path}")"
    export AZURE_CLIENT_ID="$(read_secret "${config.sops.secrets.azure-client-id.path}")"
    export AZURE_CLIENT_SECRET="$(read_secret "${config.sops.secrets.azure-client-secret.path}")"
    if [[ -z $AZURE_TENANT_ID || -z $AZURE_CLIENT_ID || -z $AZURE_CLIENT_SECRET ]]; then
      echo "Azure seal credentials are empty" >&2
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

  sops.secrets.azure-tenant-id = {
    key = azure.tenantIdKey;
    owner = "vault";
    group = "vault";
    mode = "0400";
    restartUnits = [ "vault.service" ];
  };
  sops.secrets.azure-client-id = {
    key = azure.clientIdKey;
    owner = "vault";
    group = "vault";
    mode = "0400";
    restartUnits = [ "vault.service" ];
  };
  sops.secrets.azure-client-secret = {
    key = azure.clientSecretKey;
    owner = "vault";
    group = "vault";
    mode = "0400";
    restartUnits = [ "vault.service" ];
  };

  systemd.services.vault-tls = {
    description = "Vault listener certificate";
    wantedBy = [ "vault.service" ];
    before = [ "vault.service" ];
    after = [
      "systemd-sysusers.service"
      "systemd-tmpfiles-setup.service"
      "sops-install-secrets.service"
    ];
    wants = [ "sops-install-secrets.service" ];
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
      "sops-install-secrets.service"
      "lan1-ready.service"
    ];
    after = [
      "vault-tls.service"
      "sops-install-secrets.service"
      "network-online.target"
      "lan1-ready.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      User = "vault";
      Group = "vault";
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
