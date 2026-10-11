{ commands, ... }:
{
  systemd.services.kube-scheduler = {
    description = "Kubernetes scheduler";
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
      ExecStart = commands.kubeScheduler;
      LimitNOFILE = 1048576;
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
