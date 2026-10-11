# Unit order on this single control+worker node:
#
# sops-install-secrets
#   -> kubernetes-pki
#        -> etcd -> etcd-snapshot.timer
#        -> kube-apiserver
#             -> kube-controller-manager
#             -> kube-scheduler
#             -> kube-addon-manager
#             -> kubernetes-csr-rbac -> kubelet-serving-csr-approve.timer
#        -> kubelet (also after containerd)
#             -> cilium-install
# Cilium replaces kube-proxy. Istio is installed later by Flux.
#   -> vault-tls -> vault (after network-online) -> vault-init
#
# containerd starts before kubelet and does not wait on the API.
{ self, lib, pkgs, ... }:
let
  admins = import ./admins.nix;
  commands = import ./commands.nix { inherit pkgs lib; };
  cluster = import ./cluster.nix;
  nat = builtins.attrValues cluster.natGateway;
  natPorts = protocol: map (entry: entry.port) (builtins.filter (entry: entry.protocol == protocol) nat);
in
{
  _module.args.commands = commands;
  imports = [
    admins.module
    ./systemd/sshd.nix
    ./systemd/pki.nix
    ./systemd/etcd.nix
    ./systemd/containerd.nix
    ./systemd/apiserver.nix
    ./systemd/controller-manager.nix
    ./systemd/scheduler.nix
    ./systemd/addon-manager.nix
    ./systemd/kubelet.nix
    ./systemd/csr.nix
    ./systemd/cilium.nix
    ./systemd/vault.nix
  ];

  networking.hostName = "durin";

  nix.settings.experimental-features = [ "nix-command" ];

  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "vault";

  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.age.sshKeyPaths = [ ];
  sops.defaultSopsFile = self + "/secrets/secrets.yaml";

  # Open ports only on the I210 named lan1. Other interfaces, including
  # LAN2 and the BMC USB gadget, stay closed. Loopback is allowed by the
  # firewall module itself.
  # natGateway is the set forwarded by the upstream NAT gateway.
  # The extra ports are host-local: kubelet, the Vault listener, Cilium
  # health, and Cilium VXLAN.
  networking.firewall.interfaces.${cluster.lan.interface} = {
    allowedTCPPorts = natPorts "tcp" ++ [
      10250
      8201
      4240
    ];
    allowedUDPPorts = natPorts "udp" ++ [ 8472 ];
  };

  users.groups.etcd = { };
  users.users.etcd = {
    isSystemUser = true;
    group = "etcd";
    home = "/var/lib/etcd";
  };

  users.groups.kubernetes = { };
  users.users.kubernetes = {
    isSystemUser = true;
    group = "kubernetes";
    home = "/var/lib/kubernetes";
  };

  users.groups.vault = { };
  users.users.vault = {
    isSystemUser = true;
    group = "vault";
    home = "/var/lib/vault";
  };
}
