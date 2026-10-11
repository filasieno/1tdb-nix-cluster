let
  validateOptions =
    { lib }:
    cfg:
    let
      c = import ./check.nix { inherit lib; };
      membersInput = cfg.members or null;
      membersOk = builtins.isAttrs membersInput;
      members = if membersOk then membersInput else { };
      memberNames = builtins.attrNames members;
      etcd = if builtins.isAttrs (cfg.etcd or null) then cfg.etcd else { };
      kubernetes = if builtins.isAttrs (cfg.kubernetes or null) then cfg.kubernetes else { };
      openbao = if builtins.isAttrs (cfg.openbao or null) then cfg.openbao else { };
      vault = cfg.vault or null;
      vaultNodesInput = cfg.vaultNodes or null;
      vaultNodesOk = builtins.isList vaultNodesInput;
      vaultNodes = if vaultNodesOk then vaultNodesInput else [ ];
      showName = name: if builtins.isString name then name else "<not a string>";
      vaultNodeCounts = lib.foldl' (
        acc: name:
        if builtins.isString name then acc // { ${name} = (acc.${name} or 0) + 1; } else acc
      ) { } vaultNodes;
      host = cfg.hostName or "";
      controlNames = builtins.filter (name: (members.${name}.control or false) == true) memberNames;
      addresses = map (name: members.${name}.address or null) memberNames;
      loopbacks = builtins.filter (addr: addr == "127.0.0.1") addresses;
      # Derived from cluster.bootstrap. A stored initialClusterState is not read.
      derivedState = name: if name == cfg.bootstrap then "new" else "existing";
      derivedNew = builtins.filter (name: derivedState name == "new") controlNames;
      memberAssertions = lib.concatMap (
        name:
        let
          member = members.${name};
          memberIsSet = builtins.isAttrs member;
          control = if memberIsSet then member.control or null else null;
          worker = if memberIsSet then member.worker or null else null;
        in
        [
          {
            assertion = c.hostname name;
            message = "cluster.members.${name} must be keyed by a lowercase DNS label.";
          }
          {
            assertion = builtins.isBool control && builtins.isBool worker;
            message = "cluster.members.${name}.control and cluster.members.${name}.worker must be booleans.";
          }
          {
            assertion = control == true || worker == true;
            message = "cluster.members.${name} must set control, worker, or both.";
          }
          {
            assertion = memberIsSet && c.isIpv4 (member.address or "");
            message = "cluster.members.${name}.address must be an IPv4 address. 127.0.0.1 is allowed for a single member.";
          }
        ]
      ) memberNames;
      vaultNodeAssertions = lib.concatMap (
        name:
        let
          label = showName name;
          isMember = membersOk && builtins.isString name && builtins.hasAttr name members;
          member = if isMember then members.${name} else null;
          memberIsSet = builtins.isAttrs member;
          control = if memberIsSet then member.control or null else null;
        in
        [
          {
            assertion = isMember;
            message = "cluster.vaultNodes contains \"${label}\", which is not a key of cluster.members.";
          }
          {
            assertion = !builtins.isString name || vaultNodeCounts.${name} == 1;
            message = "cluster.vaultNodes lists \"${label}\" more than once.";
          }
          {
            assertion = vault != "openbao" || !isMember || control == true;
            message = "cluster.vaultNodes entry \"${label}\" must have control = true when cluster.vault is \"openbao\".";
          }
        ]
      ) vaultNodes;
    in
    {
      assertions = [
        {
          assertion = builtins.isBool (cfg.enable or null);
          message = "cluster.enable must be a boolean.";
        }
        {
          assertion = c.hostname (cfg.name or "");
          message = "cluster.name must be a non-empty lowercase DNS label.";
        }
        {
          assertion =
            cfg.bootstrap == null
            || (
              c.hostname cfg.bootstrap
              && builtins.hasAttr cfg.bootstrap members
              && (members.${cfg.bootstrap}.control or false) == true
            );
          message = "cluster.bootstrap must be null or the hostname of a member with control = true.";
        }
        {
          assertion = builtins.length controlNames <= 1 || cfg.bootstrap != null;
          message = "Set cluster.bootstrap to the control member that minted the CA before adding a second control member.";
        }
        {
          assertion = membersOk;
          message = "cluster.members must be an attribute set of members.";
        }
        {
          assertion = loopbacks == [ ] || (builtins.length loopbacks == 1 && builtins.length memberNames == 1);
          message = "127.0.0.1 is allowed only while the cluster has a single member.";
        }
        {
          assertion = builtins.isAttrs (cfg.etcd or null);
          message = "cluster.etcd must be an attribute set.";
        }
        {
          assertion = c.nonEmptyStr (etcd.initialClusterToken or "");
          message = "cluster.etcd.initialClusterToken must be a non-empty string.";
        }
        {
          assertion = c.port (etcd.peerPort or null);
          message = "cluster.etcd.peerPort must be an integer from 1 to 65535.";
        }
        {
          assertion = c.port (etcd.clientPort or null);
          message = "cluster.etcd.clientPort must be an integer from 1 to 65535.";
        }
        {
          assertion = builtins.isAttrs (cfg.kubernetes or null);
          message = "cluster.kubernetes must be an attribute set.";
        }
        {
          assertion = c.isNetworkCidr (kubernetes.serviceCidr or "");
          message = "cluster.kubernetes.serviceCidr must be an IPv4 network in CIDR form.";
        }
        {
          assertion = c.isNetworkCidr (kubernetes.podCidr or "");
          message = "cluster.kubernetes.podCidr must be an IPv4 network in CIDR form.";
        }
        {
          assertion = c.ipInCidr (kubernetes.serviceIp or "") (kubernetes.serviceCidr or "");
          message = "cluster.kubernetes.serviceIp must be an IPv4 address inside serviceCidr.";
        }
        {
          assertion = c.absolutePath (kubernetes.secretsDir or "");
          message = "cluster.kubernetes.secretsDir must be an absolute path.";
        }
        {
          assertion = c.hostname (kubernetes.apiHost or "");
          message = "cluster.kubernetes.apiHost must be a non-empty lowercase DNS label.";
        }
        {
          assertion = c.unsigned (kubernetes.pkiGeneration or null);
          message = "cluster.kubernetes.pkiGeneration must be a non-negative integer.";
        }
        {
          assertion = (kubernetes.apiAddress or "") == "" || c.isIpv4 (kubernetes.apiAddress or "");
          message = "cluster.kubernetes.apiAddress must be empty or an IPv4 address.";
        }
        {
          assertion = builtins.length controlNames <= 1 || c.nonEmptyStr (kubernetes.apiAddress or "");
          message = "A cluster with more than one control member must set cluster.kubernetes.apiAddress. No address is invented here.";
        }
        {
          assertion = derivedNew == [ ] || derivedNew == [ cfg.bootstrap ];
          message = "etcd initialClusterState is derived from cluster.bootstrap. Only that control member is \"new\". Every other control member is \"existing\".";
        }
        {
          assertion = builtins.isAttrs (cfg.openbao or null);
          message = "cluster.openbao must be an attribute set.";
        }
        {
          assertion = c.nonEmptyStr (openbao.azureVaultName or "");
          message = "cluster.openbao.azureVaultName must be a non-empty string.";
        }
        {
          assertion = c.nonEmptyStr (openbao.azureKeyName or "");
          message = "cluster.openbao.azureKeyName must be a non-empty string.";
        }
        {
          assertion = c.nonEmptyStr (openbao.recoveryRecipient or "");
          message = "cluster.openbao.recoveryRecipient must be a non-empty age recipient.";
        }
        {
          assertion = vault == "openbao" || vault == "vault-community";
          message = "cluster.vault must be \"openbao\" or \"vault-community\".";
        }
        {
          assertion = vaultNodesOk;
          message = "cluster.vaultNodes must be a list of member hostnames.";
        }
        {
          assertion = vault != "vault-community" || (vaultNodesOk && builtins.length vaultNodes == 1);
          message = "cluster.vault is \"vault-community\". cluster.vaultNodes must list exactly one member.";
        }
        {
          assertion = vault != "openbao" || (vaultNodesOk && builtins.length vaultNodes >= 1);
          message = "cluster.vault is \"openbao\". cluster.vaultNodes must list the members that run OpenBao.";
        }
        {
          assertion = !(cfg.enable or false) || (c.hostname host && builtins.hasAttr host members);
          message = "networking.hostName must be a key in cluster.members when the cluster contract is enabled.";
        }
      ]
      ++ memberAssertions
      ++ vaultNodeAssertions;
    };

  module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.cluster;
      yaml = pkgs.formats.yaml { };
      host = config.networking.hostName;
      controlMembers = lib.filterAttrs (_: member: member.control) cfg.members;
      controlNames = lib.attrNames controlMembers;
      controlCount = lib.length controlNames;
      apiHost = if controlCount == 1 then lib.head controlNames else cfg.name;

      apiAddrOf = address: if address == "127.0.0.1" then "http://127.0.0.1:8200" else "https://${address}:8201";

      memberDoc =
        name: member:
        {
          hostname = name;
          inherit (member) control worker address;
        }
        // lib.optionalAttrs member.control {
          initialClusterState = if name == cfg.bootstrap then "new" else "existing";
          etcd = {
            peerUrl = "https://${member.address}:${toString cfg.etcd.peerPort}";
            clientUrl = "https://${member.address}:${toString cfg.etcd.clientPort}";
          };
        }
        // lib.optionalAttrs (builtins.elem name cfg.vaultNodes && cfg.vault == "openbao") {
          openbao = {
            apiAddr = apiAddrOf member.address;
            nodeId = name;
          };
        }
        // lib.optionalAttrs (builtins.elem name cfg.vaultNodes && cfg.vault == "vault-community") {
          vault = {
            apiAddr = apiAddrOf member.address;
            nodeId = name;
          };
        };

      # 127.0.0.1 is omitted so it does not override the local host.
      # With one control node, apiHost is that node's hostname.
      # With more than one, apiAddress is written here for apiHost. No address is invented.
      memberHosts = lib.foldlAttrs (
        acc: name: member:
        if member.address == "127.0.0.1" then
          acc
        else
          acc
          // {
            ${member.address} = (acc.${member.address} or [ ]) ++ [ name ];
          }
      ) { } cfg.members;
      hosts =
        if controlCount <= 1 || cfg.kubernetes.apiAddress == "" then
          memberHosts
        else
          memberHosts
          // {
            ${cfg.kubernetes.apiAddress} = lib.unique (
              (memberHosts.${cfg.kubernetes.apiAddress} or [ ]) ++ [ cfg.kubernetes.apiHost ]
            );
          };
    in
    {
      options.cluster = {
        enable = lib.mkEnableOption "the shared cluster contract";

        name = lib.mkOption {
          type = lib.types.str;
          description = "Cluster name. Used as the API host when more than one control node exists.";
        };

        bootstrap = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default =
            let
              names = lib.attrNames (
                lib.filterAttrs (_: member: member.control) config.cluster.members
              );
            in
            if lib.length names == 1 then lib.head names else null;
          defaultText = "the sole control member, or null when several control members exist";
          description = ''
            Hostname of the control member allowed to mint the cluster CA and the OpenBao listener CA.
            etcd initialClusterState is derived from this name: this member is "new",
            and every other control member is "existing".
            When the cluster has one control member this defaults to that member.
            Set it explicitly before a second control member joins.
            Other members refuse to mint. Workers never receive the CA private key.
          '';
        };

        members = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                control = lib.mkOption {
                  type = lib.types.bool;
                  description = ''
                    Run the control plane on this member: etcd, kube-apiserver,
                    controller-manager, scheduler, addon-manager, and cilium-install.
                    OpenBao is not implied. It runs only on cluster.vaultNodes when cluster.vault is "openbao".
                  '';
                };
                worker = lib.mkOption {
                  type = lib.types.bool;
                  description = ''
                    Run pod workloads on this member: containerd, kubelet, kube-proxy,
                    and Cilium host preparation. Set both booleans when one machine does both.
                  '';
                };
                address = lib.mkOption {
                  type = lib.types.str;
                  description = "Address other members dial. 127.0.0.1 is valid only while this host has no reachable address.";
                };
              };
            }
          );
          default = { };
          description = "Every node in the cluster, keyed by networking.hostName.";
        };

        etcd.initialClusterToken = lib.mkOption {
          type = lib.types.str;
          description = "Token shared by every etcd member on first formation.";
        };
        etcd.peerPort = lib.mkOption {
          type = lib.types.port;
          default = 2380;
        };
        etcd.clientPort = lib.mkOption {
          type = lib.types.port;
          default = 2379;
        };

        kubernetes.serviceCidr = lib.mkOption {
          type = lib.types.str;
          default = "10.0.0.0/24";
        };
        kubernetes.serviceIp = lib.mkOption {
          type = lib.types.str;
          default = "10.0.0.1";
        };
        kubernetes.podCidr = lib.mkOption {
          type = lib.types.str;
          default = "10.1.0.0/16";
        };
        kubernetes.secretsDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/kubernetes/secrets";
        };
        kubernetes.apiHost = lib.mkOption {
          type = lib.types.str;
          default = apiHost;
          description = "Hostname clients use for the API. One control node uses that node's name. Several use cluster.name.";
        };
        kubernetes.apiAddress = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Address that answers apiHost when more than one control member exists.
            Required in that case, and written into networking.hosts. No address
            is invented here. With one control member this stays empty.
          '';
        };
        kubernetes.pkiGeneration = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 1;
          description = ''
            Bump this to re-issue leaf certificates without rotating the CA.
            The service-account key is not regenerated when its files already exist.
            The PKI oneshot also re-issues leaves when API SANs change (this host's
            name and address, apiHost, cluster.name, or a control member address).
            A stamp file under secretsDir records the last issued generation and SAN set.
            An unchanged stamp does not rewrite certificates.
          '';
        };

        vault = lib.mkOption {
          type = lib.types.enum [
            "openbao"
            "vault-community"
          ];
          description = ''
            Which secrets process this cluster installs.
            "openbao" installs OpenBao on every hostname in cluster.vaultNodes.
            "vault-community" installs HashiCorp Vault Community on the single hostname in cluster.vaultNodes.
          '';
        };

        vaultNodes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = ''
            Hostnames that receive the process selected by cluster.vault.
            Each name must be a key of cluster.members.
            "vault-community" requires exactly one name.
            "openbao" requires at least one name, and each of those members must have control = true.
          '';
        };

        openbao.azureVaultName = lib.mkOption {
          type = lib.types.str;
          description = "Azure Key Vault name. The client secret stays in sops. Read by OpenBao and by Vault Community.";
        };
        openbao.azureKeyName = lib.mkOption {
          type = lib.types.str;
          description = "Azure Key Vault key used to unwrap OpenBao or Vault Community.";
        };
        openbao.recoveryRecipient = lib.mkOption {
          type = lib.types.str;
          description = ''
            age recipient for the recovery bundle of whichever secrets process cluster.vault selects.
            An ssh-ed25519 public key already used as an operator key. Not a secret.
          '';
        };
      };

      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } (
            cfg
            // {
              hostName = config.networking.hostName;
            }
          )).assertions;
        }
        (lib.mkIf cfg.enable {
          networking.hosts = hosts;

          services.kubernetes.masterAddress = lib.mkDefault cfg.kubernetes.apiHost;
          services.kubernetes.apiserverAddress = lib.mkDefault "https://${cfg.kubernetes.apiHost}:6443";
          services.kubernetes.clusterCidr = lib.mkDefault cfg.kubernetes.podCidr;
          services.kubernetes.package = lib.mkDefault pkgs.kubernetes;

          environment.etc = {
            "cluster/cluster.yaml".source = yaml.generate "cluster.yaml" {
              name = cfg.name;
              bootstrap = cfg.bootstrap;
              etcd = {
                initialClusterToken = cfg.etcd.initialClusterToken;
                peerPort = cfg.etcd.peerPort;
                clientPort = cfg.etcd.clientPort;
              };
              kubernetes = {
                serviceCidr = cfg.kubernetes.serviceCidr;
                serviceIp = cfg.kubernetes.serviceIp;
                podCidr = cfg.kubernetes.podCidr;
                apiHost = cfg.kubernetes.apiHost;
                apiAddress = cfg.kubernetes.apiAddress;
                secretsDir = cfg.kubernetes.secretsDir;
                pkiGeneration = cfg.kubernetes.pkiGeneration;
              };
              vault = cfg.vault;
              vaultNodes = cfg.vaultNodes;
              openbao = {
                azureVaultName = cfg.openbao.azureVaultName;
                azureKeyName = cfg.openbao.azureKeyName;
                recoveryRecipient = cfg.openbao.recoveryRecipient;
              };
              cilium = {
                ipam = "kubernetes";
                tunnelProtocol = "vxlan";
              };
            };
          }
          // lib.mapAttrs' (
            name: member:
            lib.nameValuePair "cluster/members/${name}.yaml" {
              source = yaml.generate "member-${name}.yaml" (memberDoc name member);
            }
          ) cfg.members;
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
