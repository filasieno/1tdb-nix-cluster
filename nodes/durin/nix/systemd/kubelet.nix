{
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
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
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
      "lan1-ready.service"
    ];
    requires = [
      "containerd.service"
      "kubernetes-pki.service"
      "lan1-ready.service"
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
