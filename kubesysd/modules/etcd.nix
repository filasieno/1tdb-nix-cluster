{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
      active = cfg.active or false;
    in
    {
      assertions = [
        {
          assertion = cfg.walDirectory == null || c.absolutePath cfg.walDirectory;
          message = "kubernetes.etcd.walDirectory must be null or an absolute path.";
        }
        {
          assertion = cfg.backupDirectory == null || c.absolutePath cfg.backupDirectory;
          message = "kubernetes.etcd.backupDirectory must be null or an absolute path.";
        }
        {
          assertion = !active || c.isIpv4 (cfg.address or "");
          message = "The etcd member address must be an IPv4 address.";
        }
        {
          assertion = !active || (c.port (cfg.peerPort or null) && c.port (cfg.clientPort or null));
          message = "etcd peer and client ports must be integers from 1 to 65535.";
        }
        {
          assertion = !active || c.absolutePaths (cfg.certs or [ ]);
          message = "etcd certificate paths must be absolute.";
        }
        {
          assertion =
            !active
            || (
              builtins.isList (cfg.initialCluster or null)
              && cfg.initialCluster != [ ]
              && lib.all c.hostEqualsHttps cfg.initialCluster
            );
          message = "etcd initialCluster must be a non-empty list of name=https://address:port entries.";
        }
        {
          assertion =
            !active
            || (
              (cfg.isBootstrap or false) && (cfg.initialClusterState or null) == "new"
            )
            || (
              !(cfg.isBootstrap or false) && (cfg.initialClusterState or null) == "existing"
            );
          message = "etcd initialClusterState is derived from cluster.bootstrap. That member is \"new\". Every other control member is \"existing\".";
        }
      ];
    };

  module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      k = import ../lib.nix { inherit config lib; };
      cfg = config.cluster.etcd;
      node = config.kubernetes.etcd;
      listen = port: address: "https://${address}:${toString port}";
      snapshotScript = pkgs.writeShellApplication {
        name = "etcd-snapshot";
        runtimeInputs = [
          pkgs.etcd
          pkgs.coreutils
        ];
        runtimeEnv.ETCD_BACKUP_DIR = if node.backupDirectory == null then "/var/empty" else node.backupDirectory;
        text = builtins.readFile ../scripts/etcd-snapshot.sh;
      };
      joinMembers = lib.filterAttrs (name: _: name != k.host) k.controls;
      memberAddScript = pkgs.writeShellApplication {
        name = "etcd-member-add";
        runtimeInputs = [
          pkgs.etcd
          pkgs.jq
          pkgs.coreutils
        ];
        runtimeEnv = {
          ETCD_MEMBER_NAME = k.host;
          ETCD_MEMBER_ADDRESS = if k.me == null then "" else k.me.address;
          ETCD_PEER_PORT = toString cfg.peerPort;
          ETCDCTL_ENDPOINTS = lib.concatStringsSep "," (
            lib.mapAttrsToList (
              _: member: "https://${member.address}:${toString cfg.clientPort}"
            ) joinMembers
          );
          ETCD_INITIAL_CLUSTER = lib.concatStringsSep "," (
            lib.mapAttrsToList (name: member: "${name}=${listen cfg.peerPort member.address}") k.controls
          );
          ETCDCTL_CACERT = k.cert "ca";
          ETCDCTL_CERT = k.cert "kube-apiserver-etcd-client";
          ETCDCTL_KEY = k.key "kube-apiserver-etcd-client";
        };
        text = builtins.readFile ../scripts/etcd-member-add.sh;
      };
      checked = {
        walDirectory = node.walDirectory;
        backupDirectory = node.backupDirectory;
        active = k.onControl;
        address = if k.me == null then "" else k.me.address;
        peerPort = cfg.peerPort;
        clientPort = cfg.clientPort;
        certs = [
          (k.cert "etcd")
          (k.key "etcd")
          (k.cert "ca")
        ];
        initialCluster = lib.mapAttrsToList (
          name: member: "${name}=${listen cfg.peerPort member.address}"
        ) k.controls;
        initialClusterState = k.initialClusterState;
        isBootstrap = k.isBootstrap;
      };
    in
    {
      options.kubernetes.etcd = {
        walDirectory = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Host path for the etcd WAL. Set by the node, not shared.";
        };
        backupDirectory = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Host path for etcd snapshots. Set by the node, not shared.";
        };
      };

      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onControl {
          services.etcd = {
            enable = true;
            name = k.host;
            dataDir = "/var/lib/etcd";
            listenClientUrls = [
              (listen cfg.clientPort "127.0.0.1")
            ]
            ++ lib.optional (k.me.address != "127.0.0.1") (listen cfg.clientPort k.me.address);
            listenPeerUrls = [
              (listen cfg.peerPort (if k.me.address == "127.0.0.1" then "127.0.0.1" else k.me.address))
            ];
            advertiseClientUrls = [
              (listen cfg.clientPort (if k.me.address == "127.0.0.1" then "127.0.0.1" else k.me.address))
            ];
            initialAdvertisePeerUrls = [
              (listen cfg.peerPort (if k.me.address == "127.0.0.1" then "127.0.0.1" else k.me.address))
            ];
            initialCluster = lib.mapAttrsToList (
              name: member: "${name}=${listen cfg.peerPort member.address}"
            ) k.controls;
            # Derived from cluster.bootstrap. A stored member value is not read.
            initialClusterState = k.initialClusterState;
            initialClusterToken = cfg.initialClusterToken;
            certFile = k.cert "etcd";
            keyFile = k.key "etcd";
            trustedCaFile = k.cert "ca";
            clientCertAuth = true;
            peerClientCertAuth = true;
            extraConf = lib.mkIf (node.walDirectory != null) {
              WAL_DIR = node.walDirectory;
            };
          };

          networking.firewall.allowedTCPPorts = lib.mkIf (k.me.address != "127.0.0.1") [
            cfg.clientPort
            cfg.peerPort
          ];

          systemd.services.etcd-member-add = lib.mkIf (!k.isBootstrap) {
            description = "Add this etcd member to the existing cluster before etcd starts";
            after = [ "kubernetes-pki.service" ];
            requires = [ "kubernetes-pki.service" ];
            before = [ "etcd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = 5;
              ExecStart = lib.getExe memberAddScript;
            };
          };

          systemd.services.etcd = {
            after = [ "kubernetes-pki.service" ] ++ lib.optional (!k.isBootstrap) "etcd-member-add.service";
            wants = [ "kubernetes-pki.service" ];
            requires = lib.optional (!k.isBootstrap) "etcd-member-add.service";
            serviceConfig.SupplementaryGroups = [ "kubernetes" ];
            unitConfig = lib.mkIf (node.walDirectory != null) {
              RequiresMountsFor = dirOf node.walDirectory;
            };
          };

          systemd.services.etcd-snapshot = lib.mkIf (node.backupDirectory != null) {
            description = "Save an etcd snapshot";
            after = [ "etcd.service" ];
            unitConfig.RequiresMountsFor = dirOf node.backupDirectory;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe snapshotScript;
            };
          };
          systemd.timers.etcd-snapshot = lib.mkIf (node.backupDirectory != null) {
            description = "Daily etcd snapshot";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "daily";
              Persistent = true;
              RandomizedDelaySec = "30min";
            };
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
