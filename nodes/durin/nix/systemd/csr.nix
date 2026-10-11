{
  lib,
  pkgs,
  commands,
  ...
}:
let
  cluster = import ../cluster.nix;
  binding = name: role: group: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata.name = name;
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = role;
    };
    subjects = [
      {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Group";
        name = group;
      }
    ];
  };
  userBinding = name: role: user: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata.name = name;
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = role;
    };
    subjects = [
      {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "User";
        name = user;
      }
    ];
  };
  manifests = pkgs.linkFarm "kubernetes-csr-rbac" [
    {
      name = "kubelet-bootstrap.json";
      path = pkgs.writeText "kubelet-bootstrap.json" (
        builtins.toJSON (binding "kubelet-bootstrap" "system:node-bootstrapper" "system:bootstrappers")
      );
    }
    {
      name = "kubelet-approve-nodeclient.json";
      path = pkgs.writeText "kubelet-approve-nodeclient.json" (
        builtins.toJSON (
          binding "kubelet-approve-nodeclient" "system:certificates.k8s.io:certificatesigningrequests:nodeclient" "system:bootstrappers"
        )
      );
    }
    {
      name = "kubelet-approve-selfnodeclient.json";
      path = pkgs.writeText "kubelet-approve-selfnodeclient.json" (
        builtins.toJSON (
          binding "kubelet-approve-selfnodeclient" "system:certificates.k8s.io:certificatesigningrequests:selfnodeclient" "system:nodes"
        )
      );
    }
    {
      name = "kubelet-approve-selfnodeserver.json";
      path = pkgs.writeText "kubelet-approve-selfnodeserver.json" (
        builtins.toJSON (
          binding "kubelet-approve-selfnodeserver" "system:certificates.k8s.io:certificatesigningrequests:selfnodeserver" "system:nodes"
        )
      );
    }
    {
      name = "kube-addon-manager.json";
      path = pkgs.writeText "kube-addon-manager.json" (
        builtins.toJSON (userBinding "kube-addon-manager" "cluster-admin" "system:kube-addon-manager")
      );
    }
  ];
  adminKubeconfig = import ../kubeconfig.nix {
    inherit pkgs;
    name = "cluster-admin";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "cluster-admin";
    key = cluster.key "cluster-admin";
  };
in
{
  systemd.services.kubernetes-csr-rbac = {
    description = "Allow kubelet bootstrap CSRs to be approved and signed";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kube-apiserver.service"
      "kubernetes-pki.service"
    ];
    wants = [
      "kube-apiserver.service"
      "kubernetes-pki.service"
    ];
    environment.KUBECONFIG = adminKubeconfig;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = "${pkgs.kubernetes}/bin/kubectl apply --filename ${manifests}";
    };
  };

  systemd.services.kubelet-serving-csr-approve = {
    description = "Approve kubelet serving CSRs";
    after = [
      "kubernetes-csr-rbac.service"
      "kube-apiserver.service"
      "kubernetes-pki.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe commands.approveKubeletServing;
    };
  };

  systemd.timers.kubelet-serving-csr-approve = {
    description = "Approve kubelet serving CSRs";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };
}
