# Bridge the NAT gateway ports to the Istio ingress NodePorts: the FASTGate
# forwards public 443 -> 7443 and 80 -> 8080 on this host, and these units
# carry each connection on to the istio-ingress Service.
#
# A netfilter REDIRECT/DNAT to the NodePort cannot do this here. Cilium
# replaces kube-proxy and serves NodePorts in BPF at TC ingress on lan1,
# which runs before the nat PREROUTING hook; a packet rewritten there to
# :30443 reaches the local stack, where no socket listens, and is refused.
# systemd-socket-proxyd instead connects from the host namespace, where
# Cilium's socket LB (hostNamespaceOnly) picks the ingress backend.
#
# The firewall already opens these ports on lan1: default.nix opens every
# natGateway port there. FreeBind lets the socket bind the pinned address
# before lan1 is renamed and configured.
{ lib, pkgs, ... }:
let
  cluster = import ../cluster.nix;
  address = cluster.lan.address;
  forwards = lib.mapAttrs' (
    name: entry: lib.nameValuePair "ingress-forward-${name}" entry
  ) (lib.filterAttrs (_: entry: entry ? nodePort) cluster.natGateway);
in
{
  systemd.sockets = lib.mapAttrs (unit: entry: {
    description = "Listener on ${address}:${builtins.toString entry.port} for the Istio ingress";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "${address}:${builtins.toString entry.port}";
      FreeBind = true;
    };
  }) forwards;

  systemd.services = lib.mapAttrs (unit: entry: {
    description = "Forward ${builtins.toString entry.port} to ingress NodePort ${builtins.toString entry.nodePort}";
    requires = [ "${unit}.socket" ];
    after = [ "${unit}.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${address}:${builtins.toString entry.nodePort}";
      DynamicUser = true;
      PrivateTmp = true;
    };
  }) forwards;
}
