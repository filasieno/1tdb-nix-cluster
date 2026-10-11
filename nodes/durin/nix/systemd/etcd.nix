{
  lib,
  commands,
  ...
}:
let
  cluster = import ../cluster.nix;
in
{
  systemd.services.etcd = {
    description = "etcd";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kubernetes-pki.service"
      "network-online.target"
    ];
    requires = [ "kubernetes-pki.service" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = cluster.walMount;
    environment = {
      ETCD_NAME = cluster.host;
      ETCD_DATA_DIR = "/var/lib/etcd";
      ETCD_WAL_DIR = cluster.walDirectory;
      ETCD_LISTEN_CLIENT_URLS = cluster.etcdClient;
      ETCD_ADVERTISE_CLIENT_URLS = cluster.etcdClient;
      ETCD_LISTEN_PEER_URLS = "https://${cluster.address}:2380";
      ETCD_INITIAL_ADVERTISE_PEER_URLS = "https://${cluster.address}:2380";
      ETCD_INITIAL_CLUSTER = "${cluster.host}=https://${cluster.address}:2380";
      ETCD_INITIAL_CLUSTER_TOKEN = cluster.etcdToken;
      ETCD_CERT_FILE = cluster.cert "etcd";
      ETCD_KEY_FILE = cluster.key "etcd";
      ETCD_TRUSTED_CA_FILE = cluster.cert "ca";
      ETCD_CLIENT_CERT_AUTH = "true";
      ETCD_PEER_CERT_FILE = cluster.cert "etcd";
      ETCD_PEER_KEY_FILE = cluster.key "etcd";
      ETCD_PEER_TRUSTED_CA_FILE = cluster.cert "ca";
      ETCD_PEER_CLIENT_CERT_AUTH = "true";
    };
    serviceConfig = {
      Type = "notify";
      User = "etcd";
      Group = "etcd";
      Restart = "always";
      RestartSec = "30s";
      LimitNOFILE = 40000;
      OOMScoreAdjust = -999;
      MemoryAccounting = true;
      ExecStartPre = "+${commands.etcdPrepare}";
      ExecStart = commands.etcdStart;
      StateDirectory = "etcd";
    };
  };

  systemd.services.etcd-snapshot = {
    description = "Save an etcd snapshot";
    after = [ "etcd.service" ];
    requires = [ "etcd.service" ];
    unitConfig.RequiresMountsFor = "/data";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe commands.etcdSnapshot;
    };
  };

  systemd.timers.etcd-snapshot = {
    description = "Daily etcd snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };
}
