{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
      active = cfg.active or false;
      sopsSet =
        file:
        file != null && (builtins.isPath file || (builtins.isString file && file != ""));
    in
    {
      assertions = [
        {
          assertion = !active || cfg.clusterEnable == true;
          message = "OpenBao requires the cluster contract.";
        }
        {
          assertion = !active || (c.nonEmptyStr (cfg.vaultName or "") && c.nonEmptyStr (cfg.keyName or ""));
          message = "OpenBao requires a non-empty Azure vault name and key name. The client secret stays in sops.";
        }
        {
          assertion = !active || (c.loopbackOrHttps (cfg.apiAddr or "") && c.loopbackOrHttps (cfg.clusterAddr or ""));
          message = "OpenBao api and cluster addresses must be https, or http://127.0.0.1 when the member address is loopback.";
        }
        {
          assertion = !active || c.absolutePaths (cfg.paths or [ ]);
          message = "OpenBao TLS and Raft paths must be absolute.";
        }
        {
          assertion = !active || c.hostname (cfg.nodeId or "");
          message = "OpenBao node id must be a lowercase DNS label.";
        }
        {
          assertion = !active || (c.port (cfg.localPort or null) && c.port (cfg.publicPort or null) && c.port (cfg.clusterPort or null));
          message = "OpenBao ports must be integers from 1 to 65535.";
        }
        {
          assertion = !active || sopsSet (cfg.sopsFile or null);
          message = "A vault node must set sops.defaultSopsFile. OpenBao reads the Azure seal from that file. The client secret stays there, not in Nix.";
        }
        {
          assertion = !active || cfg.openbaoEnable == true;
          message = "A vault node enables OpenBao.";
        }
        {
          assertion = !active || c.nonEmptyStr (cfg.recoveryRecipient or "");
          message = "OpenBao recovery recipient must be the age recipient from the cluster contract.";
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
      onVault =
        if options.cluster ? vault && options.cluster ? vaultNodes then
          known && config.cluster.vault == "openbao" && builtins.elem host config.cluster.vaultNodes
        else
          false;
      peers =
        if options.cluster ? vaultNodes then
          lib.filterAttrs (
            name: _: name != host && builtins.elem name config.cluster.vaultNodes
          ) config.cluster.members
        else
          { };
      apiAddr =
        address: if address == "127.0.0.1" then "http://127.0.0.1:8200" else "https://${address}:8201";
      clusterAddr =
        address: if address == "127.0.0.1" then "http://127.0.0.1:8202" else "https://${address}:8202";
      tlsScript = pkgs.writeShellApplication {
        name = "openbao-tls";
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        runtimeEnv = {
          OPENBAO_TLS_DIR = "/var/lib/openbao/tls";
          OPENBAO_TLS_HOSTNAME = host;
          OPENBAO_TLS_ADDRESS = if me == null then "127.0.0.1" else me.address;
          OPENBAO_TLS_BOOTSTRAP = if config.cluster.bootstrap == host then "1" else "0";
        };
        text = builtins.readFile ./tls.sh;
      };
      openbaoBootstrap = config.cluster.bootstrap == host;
      initMarker = "# BOOTSTRAP_OPERATOR_INIT";
      initSource = builtins.readFile ./init.sh;
      initParts = lib.splitString initMarker initSource;
      initText =
        if openbaoBootstrap then
          initSource
        else if builtins.length initParts != 2 then
          throw "kubesysd/openbao/init.sh is missing the bootstrap init marker"
        else
          builtins.head initParts
          + ''
            echo "openbao-init: not cluster.bootstrap. Refusing to initialize." >&2
            exit 1
          '';
      initScript = pkgs.writeShellApplication {
        name = "openbao-init";
        runtimeInputs = [
          pkgs.openbao
          pkgs.jq
          pkgs.age
          pkgs.coreutils
          pkgs.etcd
        ];
        runtimeEnv = {
          OPENBAO_BOOTSTRAP = if openbaoBootstrap then "1" else "0";
          BAO_ADDR = "http://127.0.0.1:8200";
          OPENBAO_RECOVERY_RECIPIENT = config.cluster.openbao.recoveryRecipient;
          ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
          ETCDCTL_CACERT = "${config.cluster.kubernetes.secretsDir}/ca.pem";
          ETCDCTL_CERT = "${config.cluster.kubernetes.secretsDir}/kube-apiserver-etcd-client.pem";
          ETCDCTL_KEY = "${config.cluster.kubernetes.secretsDir}/kube-apiserver-etcd-client-key.pem";
        };
        text = initText;
      };
      checked = {
        active = onVault;
        clusterEnable = config.cluster.enable;
        vaultName = config.cluster.openbao.azureVaultName;
        keyName = config.cluster.openbao.azureKeyName;
        apiAddr = if me == null then "" else apiAddr me.address;
        clusterAddr = if me == null then "" else clusterAddr me.address;
        paths = [
          "/var/lib/openbao/tls/tls.crt"
          "/var/lib/openbao/tls/tls.key"
          "/var/lib/openbao"
        ];
        nodeId = host;
        localPort = 8200;
        publicPort = 8201;
        clusterPort = 8202;
        sopsFile = config.sops.defaultSopsFile;
        openbaoEnable = config.services.openbao.enable;
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
        (lib.mkIf onVault {
          users.users.openbao = {
            isSystemUser = true;
            group = "openbao";
          };
          users.groups.openbao = { };

          networking.firewall.allowedTCPPorts = [
            8201
            8202
          ];

          systemd.tmpfiles.rules = [
            "d /var/lib/openbao/tls 0750 openbao openbao -"
          ];

          systemd.services.openbao-tls = {
            description = "OpenBao listener certificate. Only cluster.bootstrap may mint the CA, and only when ca.crt is absent.";
            wantedBy = [ "openbao.service" ];
            before = [ "openbao.service" ];
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

          services.openbao = {
            enable = true;
            settings = {
              ui = false;
              disable_mlock = true;
              api_addr = apiAddr me.address;
              cluster_addr = clusterAddr me.address;
              listener.local = {
                type = "tcp";
                address = "127.0.0.1:8200";
                tls_disable = true;
              };
              listener.public = {
                type = "tcp";
                address = "0.0.0.0:8201";
                tls_cert_file = "/var/lib/openbao/tls/tls.crt";
                tls_key_file = "/var/lib/openbao/tls/tls.key";
                tls_min_version = "tls12";
              };
              storage.raft = {
                path = "/var/lib/openbao";
                node_id = host;
              }
              // lib.optionalAttrs (peers != { }) {
                retry_join = lib.mapAttrsToList (
                  _: member:
                  {
                    leader_api_addr = apiAddr member.address;
                  }
                  // lib.optionalAttrs (member.address != "127.0.0.1") {
                    # PEM is not known at evaluation. OpenBao reads this file
                    # at start. Loopback peers speak HTTP and do not set it.
                    leader_ca_cert_file = "/var/lib/openbao/tls/ca.crt";
                  }
                ) peers;
              };
              seal.azurekeyvault = {
                vault_name = config.cluster.openbao.azureVaultName;
                key_name = config.cluster.openbao.azureKeyName;
              };
            };
          };

          sops.secrets.azure-tenant-id = {
            key = "azure_tenant_id";
            owner = "openbao";
            group = "openbao";
            mode = "0400";
          };
          sops.secrets.azure-client-id = {
            key = "azure_client_id";
            owner = "openbao";
            group = "openbao";
            mode = "0400";
          };
          sops.secrets.azure-client-secret = {
            key = "azure_client_secret";
            owner = "openbao";
            group = "openbao";
            mode = "0400";
          };
          sops.templates."azure-keyvault.env" = {
            owner = "openbao";
            mode = "0400";
            restartUnits = [ "openbao.service" ];
            content = ''
              AZURE_TENANT_ID="${config.sops.placeholder.azure-tenant-id}"
              AZURE_CLIENT_ID="${config.sops.placeholder.azure-client-id}"
              AZURE_CLIENT_SECRET="${config.sops.placeholder.azure-client-secret}"
            '';
          };

          systemd.services.openbao = {
            after = [
              "sops-install-secrets.service"
              "openbao-tls.service"
            ];
            wants = [
              "sops-install-secrets.service"
              "openbao-tls.service"
            ];
            serviceConfig = {
              DynamicUser = lib.mkForce false;
              User = lib.mkForce "openbao";
              Group = lib.mkForce "openbao";
              EnvironmentFile = config.sops.templates."azure-keyvault.env".path;
            };
          };

          systemd.services.openbao-init = {
            description =
              if openbaoBootstrap then
                "Initialize OpenBao once under an etcd lock"
              else
                "Wait until OpenBao is initialized. This member does not initialize.";
            wantedBy = [ "openbao.service" ];
            after = [
              "openbao.service"
              "etcd.service"
              "kubernetes-pki.service"
            ];
            wants = [
              "etcd.service"
              "kubernetes-pki.service"
            ];
            environment.OPENBAO_BOOTSTRAP = if openbaoBootstrap then "1" else "0";
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
        # Inactive until openbao_ca_cert / openbao_ca_key exist in the host
        # sops file. No ciphertext is committed for them. The bootstrap
        # member keeps minting ca.crt on disk while these stay off.
        # A later control member uses the installed ca.crt and does not mint.
        (lib.mkIf (onVault && sopsHasKey "openbao_ca_cert") {
          sops.secrets.openbao-ca = {
            key = "openbao_ca_cert";
            owner = "openbao";
            group = "openbao";
            mode = "0444";
            path = "/var/lib/openbao/tls/ca.crt";
            restartUnits = [
              "openbao-tls.service"
              "openbao.service"
            ];
          };
        })
        (lib.mkIf (onVault && sopsHasKey "openbao_ca_key") {
          sops.secrets.openbao-ca-key = {
            key = "openbao_ca_key";
            owner = "openbao";
            group = "openbao";
            mode = "0400";
            path = "/var/lib/openbao/tls/ca.key";
            restartUnits = [ "openbao-tls.service" ];
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
