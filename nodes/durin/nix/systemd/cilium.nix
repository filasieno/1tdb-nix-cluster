{ lib, commands, ... }:
{
  systemd.services.cilium-install = {
    description = "Install Cilium";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kube-apiserver.service"
      "etcd.service"
      "kubelet.service"
    ];
    wants = [
      "kube-apiserver.service"
      "etcd.service"
      "kubelet.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "900s";
      ExecStart = lib.getExe commands.installCilium;
    };
  };
}
