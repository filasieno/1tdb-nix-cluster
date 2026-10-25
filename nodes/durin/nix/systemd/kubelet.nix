{
  config,
  lib,
  pkgs,
  commands,
  ...
}:
{
  boot.kernelModules = [
    "br_netfilter"
    "overlay"
  ];
  # br_netfilter must NOT run iptables on bridged frames. The node address is
  # on br0 and Cilium's BPF DNAT for NodePort/externalIPs runs on br0 itself,
  # after the bridge. With bridge-nf-call-iptables=1 conntrack sees the
  # inbound SYN on the bridge port with the pre-DNAT destination
  # (37.156.174.22:443), so the pod's reply from 10.1.0.74:443 looks like a
  # new flow, hits Cilium's iptables MASQUERADE, and gets a different source
  # port (443 is "taken" by the stale entry). Clients then never see the TLS
  # ServerHello and every public UI times out (2026-10-25 outage). The module
  # stays in kernelModules because the net.bridge.* keys only exist while it
  # is loaded; the hooks stay off.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;
    "net.ipv4.ip_forward" = lib.mkForce 1;
  };

  systemd.services.kubelet = {
    description = "Kubernetes kubelet";
    wantedBy = [ "multi-user.target" ];
    after = [
      "containerd.service"
      "kubernetes-pki.service"
      "kube-apiserver.service"
      "network-online.target"
      "br0-ready.service"
    ];
    requires = [
      "containerd.service"
      "kubernetes-pki.service"
      "br0-ready.service"
    ];
    wants = [
      "kube-apiserver.service"
      "network-online.target"
    ];
    path = [
      pkgs.iproute2
      pkgs.iptables
      pkgs.ethtool
      pkgs.socat
      pkgs.util-linux
      # cAdvisor shells out to the zfs tools to stat the root filesystem
      # (rpool/var); without them the kubelet fails with "cannot find
      # filesystem info for device rpool/var".
      config.boot.zfs.package
    ];
    serviceConfig = {
      Delegate = "yes";
      KillMode = "process";
      Restart = "always";
      RestartSec = "5s";
      MemoryAccounting = true;
      CPUAccounting = true;
      LimitNOFILE = 1048576;
      OOMScoreAdjust = -900;
      WorkingDirectory = "/var/lib/kubernetes";
      ExecStartPre = commands.kubeletPrepare;
      ExecStart = commands.kubelet;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
