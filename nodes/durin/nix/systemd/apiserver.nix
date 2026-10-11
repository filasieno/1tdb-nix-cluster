{ lib, commands, ... }:
{
  systemd.services.kube-apiserver = {
    description = "Kubernetes API server";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "etcd.service"
      "kubernetes-pki.service"
      "lan1-ready.service"
    ];
    after = [
      "etcd.service"
      "kubernetes-pki.service"
      "network.target"
      "lan1-ready.service"
    ];
    # These units BindsTo this one. Upholds starts them again after an
    # apiserver restart instead of leaving them stopped.
    upholds = [
      "kube-controller-manager.service"
      "kube-scheduler.service"
      "kube-addon-manager.service"
    ];
    # Re-read the serving certificate after pki.sh changes the SAN list.
    restartTriggers = [ (lib.getExe commands.pki) ];
    serviceConfig = {
      User = "kubernetes";
      Group = "kubernetes";
      Restart = "always";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/kubernetes";
      ExecStart = commands.kubeApiserver;
      LimitNOFILE = 1048576;
      OOMScoreAdjust = -800;
      MemoryAccounting = true;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
