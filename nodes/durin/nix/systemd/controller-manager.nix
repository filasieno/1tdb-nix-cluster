{ commands, ... }:
{
  systemd.services.kube-controller-manager = {
    description = "Kubernetes controller manager";
    wantedBy = [ "multi-user.target" ];
    after = [ "kube-apiserver.service" ];
    bindsTo = [ "kube-apiserver.service" ];
    wants = [ "kube-apiserver.service" ];
    serviceConfig = {
      User = "kubernetes";
      Group = "kubernetes";
      Restart = "always";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/kubernetes";
      ExecStart = commands.kubeControllerManager;
      LimitNOFILE = 1048576;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
