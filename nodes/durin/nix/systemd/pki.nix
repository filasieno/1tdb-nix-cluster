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
    # 0751: etcd is not in group kubernetes but must traverse the directory
    # to open its own certificate pair, which carries its own modes.
    "d ${cluster.secrets} 0751 root kubernetes -"
  ];

  systemd.services.kubernetes-pki = {
    description = "Issue the Kubernetes certificates for durin";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-sysusers.service"
      "systemd-tmpfiles-setup.service"
    ];
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
