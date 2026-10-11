{
  lib,
  commands,
  ...
}:
let
  cluster = import ../cluster.nix;
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/kubernetes 0755 kubernetes kubernetes -"
    "d ${cluster.secrets} 0750 root kubernetes -"
  ];

  systemd.services.kubernetes-pki = {
    description = "Issue the Kubernetes certificates for durin";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-sysusers.service"
      "systemd-tmpfiles-setup.service"
      "sops-install-secrets.service"
    ];
    wants = [ "sops-install-secrets.service" ];
    before = [
      "etcd.service"
      "kube-apiserver.service"
      "kubelet.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe commands.pki;
    };
  };

  system.activationScripts.kubernetes-admin-kubeconfig.text = ''
    ${lib.getExe commands.adminKubeconfig}
  '';
}
