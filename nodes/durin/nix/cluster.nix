# Durin is the only member: control plane, worker, and bootstrap.
let
  admins = import ./admins.nix;
  apiDomain = import ./api-domain.nix;
in
rec {
  host = "durin";
  name = "1tdb";
  address = "127.0.0.1";
  # Intel I210 LAN1. Published ports are opened only on this card.
  # The gateway is the FASTGate on this subnet.
  lan = {
    interface = "lan1";
    mac = "90:5a:08:c2:f9:56";
    address = "192.168.1.230";
    prefix = 24;
    gateway = "192.168.1.254";
    dns = "192.168.1.254";
  };
  etcdToken = "1tdb-1";
  serviceCidr = "10.0.0.0/24";
  serviceIp = "10.0.0.1";
  podCidr = "10.1.0.0/16";
  clusterDns = "10.0.0.10";
  secrets = "/var/lib/kubernetes/secrets";

  # Ports the upstream NAT gateway forwards to this host.
  # sshd, the apiserver, and the host firewall all read this set.
  # Change a number here; do not duplicate it in a unit.
  natGateway = {
    apiserver = {
      port = 6443;
      protocol = "tcp";
    };
    http = {
      port = 8080;
      protocol = "tcp";
    };
    https = {
      port = 7443;
      protocol = "tcp";
    };
    telepresence = {
      port = 7778;
      protocol = "udp";
    };
    ssh = {
      port = 2222;
      protocol = "tcp";
    };
  };
  # Control-plane clients stay on loopback. The certificate includes it.
  # Admin kubeconfigs use publicApiServer, which this host also resolves
  # to lan.address. See nodes/durin/README.md.
  apiServer = "https://${address}:${builtins.toString natGateway.apiserver.port}";
  publicApiServer = "https://${apiDomain.client}:${builtins.toString natGateway.apiserver.port}";
  etcdClient = "https://${address}:2379";
  walDirectory = "/var/lib/etcd-wal/wal";
  walMount = "/var/lib/etcd-wal";
  backupDirectory = "/data/etcd-backups";
  recoveryRecipients = [
    admins.fabio
    admins.roby
  ];

  cert = component: "${secrets}/${component}.pem";
  key = component: "${secrets}/${component}-key.pem";
}
