# Durin is the only member: control plane, worker, and bootstrap.
let
  admins = import ./admins.nix;
  apiDomain = import ./api-domain.nix;
in
rec {
  host = "durin";
  name = "1tdb";
  address = "127.0.0.1";
  # Both onboard I210 ports are bridge members. The address is the
  # datacenter address and lives on the bridge, not on either card.
  # The bridge MAC is eno2, which already owns this address on the switch.
  lan = {
    interface = "br0";
    mac = "90:5a:08:c2:f9:57";
    address = "37.156.174.22";
    prefix = 24;
    gateway = "37.156.174.1";
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    members = [
      {
        name = "eno1";
        mac = "90:5a:08:c2:f9:56";
      }
      {
        name = "eno2";
        mac = "90:5a:08:c2:f9:57";
      }
    ];
  };
  etcdToken = "1tdb-1";
  serviceCidr = "10.0.0.0/24";
  serviceIp = "10.0.0.1";
  podCidr = "10.1.0.0/16";
  clusterDns = "10.0.0.10";
  secrets = "/var/lib/kubernetes/secrets";

  # Ports opened on the bridge. sshd, the apiserver, and the host firewall
  # all read this set. Change a number here; do not duplicate it in a unit.
  # HTTP and HTTPS on 80 and 443 are published by the GitOps Service
  # istio-ingress-public. Entries with a nodePort are still bridged by
  # systemd/ingress-forward.nix. The NodePort numbers are fixed in
  # 1tdb-cluster, infrastructure/istio/gateway/helmrelease.yaml.
  natGateway = {
    apiserver = {
      port = 6443;
      protocol = "tcp";
    };
    http = {
      port = 8080;
      protocol = "tcp";
      nodePort = 30080;
    };
    https = {
      port = 7443;
      protocol = "tcp";
      nodePort = 30443;
    };
    telepresence = {
      port = 7778;
      protocol = "udp";
    };
    ssh = {
      port = 22;
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
