{ pkgs, ... }:
let
  cluster = import ../cluster.nix;
  kubeconfig = import ../kubeconfig.nix {
    inherit pkgs;
    name = "kube-addon-manager";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "kube-addon-manager";
    key = cluster.key "kube-addon-manager";
  };
in
{
  systemd.services.kube-addon-manager = {
    description = "Kubernetes addon manager";
    wantedBy = [ "multi-user.target" ];
    after = [ "kube-apiserver.service" ];
    bindsTo = [ "kube-apiserver.service" ];
    wants = [ "kube-apiserver.service" ];
    environment = {
      ADDON_PATH = "${../../addons}";
      KUBECONFIG = kubeconfig;
    };
    path = [ pkgs.gawk ];
    serviceConfig = {
      User = "kubernetes";
      Group = "kubernetes";
      Restart = "always";
      RestartSec = "10s";
      WorkingDirectory = "/var/lib/kubernetes";
      ExecStart = "${pkgs.kubernetes}/bin/kube-addons";
    };
    unitConfig.StartLimitIntervalSec = 0;
  };
}
