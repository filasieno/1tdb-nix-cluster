# Unit order on this single control+worker node:
#
# kubernetes-pki
#   -> etcd -> etcd-snapshot.timer
#   -> kube-apiserver
#        -> kube-controller-manager
#        -> kube-scheduler
#        -> kube-addon-manager
#        -> kubernetes-csr-rbac -> kubelet-serving-csr-approve.timer
#   -> kubelet (also after containerd)
#        -> cilium-install
# Cilium replaces kube-proxy. Istio is installed later by Flux.
# vault-tls -> vault (after network-online, TPM-sealed Azure secret) -> vault-init
#   -> vault-platform-admin (after the API; retries until Flux has created
#      vault-platform-admin-sa, then grants it cluster-admin and enables
#      Vault kubernetes auth)
#
# containerd starts before kubelet and does not wait on the API.
{ lib, pkgs, ... }:
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
    ./systemd/ingress-forward.nix
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
    ./systemd/vault-platform-admin.nix
  ];

  networking.hostName = "durin";

  nix.settings.experimental-features = [ "nix-command" ];

  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "vault";

  # Admin CLI suite for interactive cluster operation. The systemd units
  # carry their own runtimeInputs in commands.nix; this list is what admin
  # login shells see on PATH.
  environment.systemPackages = [
    pkgs.kubectl
    pkgs.kubernetes-helm
    pkgs.cilium-cli
    pkgs.hubble
    pkgs.istioctl
    pkgs.skopeo
    pkgs.nerdctl
    pkgs.kustomize
    pkgs.k9s
    pkgs.stern
    pkgs.kubectx
    pkgs.kyverno # kyverno CLI
    pkgs.fluxcd # flux CLI only; GitOps bootstrap is separate
    pkgs.crane # go-containerregistry
    pkgs.etcd # etcdctl, etcdutl
    pkgs.cfssl
    pkgs.jq
    pkgs.yq-go
    pkgs.kubecolor
    pkgs.ipmitool
  ];

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

  # Pod traffic enters the host through the Cilium datapath devices, not
  # lan1: a pod reaching the apiserver ClusterIP is BPF-translated to
  # 192.168.1.230:6443 and would otherwise hit the default drop. Cilium
  # network policy governs that path; the host firewall trusts it.
  networking.firewall.trustedInterfaces = [
    "cilium_host"
    "cilium_net"
    "cilium_vxlan"
    "lxc+"
  ];

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
