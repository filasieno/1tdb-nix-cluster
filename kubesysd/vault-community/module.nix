{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
      active = cfg.active or false;
      implementation = cfg.implementation or null;
      nodes = cfg.vaultNodes or [ ];
      sopsSet =
        file:
        file != null && (builtins.isPath file || (builtins.isString file && file != ""));
    in
    {
      assertions = [
        {
          assertion = implementation != "vault-community" || (builtins.isList nodes && builtins.length nodes == 1);
          message = "cluster.vault is \"vault-community\". cluster.vaultNodes must list exactly one member.";
        }
        {
          assertion = !active || cfg.clusterEnable == true;
          message = "Vault community requires the cluster contract.";
        }
        {
          assertion = !active || (c.nonEmptyStr (cfg.vaultName or "") && c.nonEmptyStr (cfg.keyName or ""));
          message = "Vault community requires a non-empty Azure vault name and key name. The client secret stays in sops.";
        }
        {
          assertion = !active || c.loopbackOrHttps (cfg.apiAddr or "");
          message = "Vault community api address must be https, or http://127.0.0.1 when the member address is loopback.";
        }
        {
          assertion = !active || c.absolutePaths (cfg.paths or [ ]);
          message = "Vault community TLS paths must be absolute.";
        }
        {
          assertion = !active || c.hostname (cfg.nodeId or "");
          message = "Vault community node id must be a lowercase DNS label.";
        }
        {
          assertion = !active || (c.port (cfg.localPort or null) && c.port (cfg.publicPort or null));
          message = "Vault community ports must be integers from 1 to 65535.";
        }
        {
          assertion = !active || sopsSet (cfg.sopsFile or null);
          message = "The Vault community node must set sops.defaultSopsFile. Vault reads the Azure seal from that file. The client secret stays there, not in Nix.";
        }
        {
          assertion = !active || cfg.vaultEnable == true;
          message = "The Vault community node enables HashiCorp Vault community.";
        }
        {
          assertion = !active || c.nonEmptyStr (cfg.recoveryRecipient or "");
          message = "Vault community recovery recipient must be the age recipient from the cluster contract.";
        }
      ];
    };

  module =
    {
      config,
      options,
      lib,
      pkgs,
      ...
    }:
    let
      host = config.networking.hostName;
      known = builtins.hasAttr host config.cluster.members;
      me = if known then config.cluster.members.${host} else null;
      # config.cluster.vault and config.cluster.vaultNodes are read only in the true branch.
      choice =
        if options.cluster ? vault && options.cluster ? vaultNodes then
          {
            implementation = config.cluster.vault;
            nodes = config.cluster.vaultNodes;
          }
        else
          {
            implementation = null;
            nodes = [ ];
          };
      countOk = builtins.isList choice.nodes && builtins.length choice.nodes == 1;
      active =
        choice.implementation == "vault-community" && countOk && known && builtins.elem host choice.nodes;
      apiAddrOf =
        address: if address == "127.0.0.1" then "http://127.0.0.1:8200" else "https://${address}:8201";
      apiAddr = if me == null then "" else apiAddrOf me.address;
      tlsScript = pkgs.writeShellApplication {
        name = "vault-tls";
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        runtimeEnv = {
          VAULT_TLS_DIR = "/var/lib/vault/tls";
          VAULT_TLS_HOSTNAME = host;
          VAULT_TLS_ADDRESS = if me == null then "127.0.0.1" else me.address;
        };
        text = builtins.readFile ./tls.sh;
      };
      initScript = pkgs.writeShellApplication {
        name = "vault-init";
        runtimeInputs = [
          pkgs.vault
          pkgs.jq
          pkgs.age
          pkgs.coreutils
        ];
        runtimeEnv = {
          VAULT_ADDR = "http://127.0.0.1:8200";
          VAULT_RECOVERY_RECIPIENT = config.cluster.openbao.recoveryRecipient;
        };
        text = builtins.readFile ./init.sh;
      };
      checked = {
        active = active;
        implementation = choice.implementation;
        vaultNodes = choice.nodes;
        clusterEnable = config.cluster.enable;
        vaultName = config.cluster.openbao.azureVaultName;
        keyName = config.cluster.openbao.azureKeyName;
        inherit apiAddr;
        paths = [
          "/var/lib/vault/tls/tls.crt"
          "/var/lib/vault/tls/tls.key"
        ];
        nodeId = host;
        localPort = 8200;
        publicPort = 8201;
        sopsFile = config.sops.defaultSopsFile;
        vaultEnable = config.services.vault.enable;
        recoveryRecipient = config.cluster.openbao.recoveryRecipient;
      };
      sopsFile = config.sops.defaultSopsFile;
      sopsText =
        let
          existing =
            if sopsFile == null then
              null
            else if builtins.isPath sopsFile then
              sopsFile
            else if builtins.isString sopsFile && builtins.pathExists sopsFile then
              sopsFile
            else
              null;
        in
        if existing == null then "" else builtins.readFile existing;
      sopsHasKey = key: lib.hasPrefix "${key}:" sopsText || lib.hasInfix "\n${key}:" sopsText;
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf active {
          networking.firewall.allowedTCPPorts = [ 8201 ];

          systemd.tmpfiles.rules = [
            "d /var/lib/vault/tls 0750 vault vault -"
          ];

          systemd.services.vault-tls = {
            description = "Vault Community listener certificate. This node mints the CA when ca.crt is absent.";
            wantedBy = [ "vault.service" ];
            before = [ "vault.service" ];
            after = [
              "systemd-tmpfiles-setup.service"
              "sops-install-secrets.service"
            ];
            wants = [ "sops-install-secrets.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe tlsScript;
            };
          };

          services.vault = {
            enable = true;
            package = pkgs.vault;
            address = "127.0.0.1:8200";
            storageBackend = "file";
            storagePath = "/var/lib/vault";
            extraConfig = ''
              ui = false
              disable_mlock = true
              api_addr = "${apiAddr}"

              listener "tcp" {
                address = "0.0.0.0:8201"
                tls_cert_file = "/var/lib/vault/tls/tls.crt"
                tls_key_file = "/var/lib/vault/tls/tls.key"
                tls_min_version = "tls12"
              }

              seal "azurekeyvault" {
                vault_name = "${config.cluster.openbao.azureVaultName}"
                key_name = "${config.cluster.openbao.azureKeyName}"
              }
            '';
          };

          sops.secrets.azure-tenant-id = {
            key = "azure_tenant_id";
            owner = "vault";
            group = "vault";
            mode = "0400";
          };
          sops.secrets.azure-client-id = {
            key = "azure_client_id";
            owner = "vault";
            group = "vault";
            mode = "0400";
          };
          sops.secrets.azure-client-secret = {
            key = "azure_client_secret";
            owner = "vault";
            group = "vault";
            mode = "0400";
          };
          sops.templates."vault-azure-keyvault.env" = {
            owner = "vault";
            mode = "0400";
            restartUnits = [ "vault.service" ];
            content = ''
              AZURE_TENANT_ID="${config.sops.placeholder.azure-tenant-id}"
              AZURE_CLIENT_ID="${config.sops.placeholder.azure-client-id}"
              AZURE_CLIENT_SECRET="${config.sops.placeholder.azure-client-secret}"
            '';
          };

          systemd.services.vault = {
            after = [
              "sops-install-secrets.service"
              "vault-tls.service"
            ];
            wants = [
              "sops-install-secrets.service"
              "vault-tls.service"
            ];
            serviceConfig.EnvironmentFile = config.sops.templates."vault-azure-keyvault.env".path;
          };

          systemd.services.vault-init = {
            description = "Initialize HashiCorp Vault Community once";
            wantedBy = [ "vault.service" ];
            after = [ "vault.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = 5;
              User = "root";
              ExecStart = lib.getExe initScript;
            };
          };
        })
        (lib.mkIf (active && sopsHasKey "vault_ca_cert") {
          sops.secrets.vault-ca = {
            key = "vault_ca_cert";
            owner = "vault";
            group = "vault";
            mode = "0444";
            path = "/var/lib/vault/tls/ca.crt";
            restartUnits = [
              "vault-tls.service"
              "vault.service"
            ];
          };
        })
        (lib.mkIf (active && sopsHasKey "vault_ca_key") {
          sops.secrets.vault-ca-key = {
            key = "vault_ca_key";
            owner = "vault";
            group = "vault";
            mode = "0400";
            path = "/var/lib/vault/tls/ca.key";
            restartUnits = [ "vault-tls.service" ];
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
