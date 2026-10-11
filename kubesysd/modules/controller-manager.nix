{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
    in
    {
      assertions = [
        {
          assertion = !(cfg.active or false) || c.absolutePaths (cfg.certs or [ ]);
          message = "kube-controller-manager certificate paths must be absolute.";
        }
      ];
    };

  module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      k = import ../lib.nix { inherit config lib; };
      csrBinding = name: role: group: {
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
      csrManifests = pkgs.linkFarm "kubelet-csr-rbac" [
        {
          name = "kubelet-bootstrap.json";
          path = pkgs.writeText "kubelet-bootstrap.json" (
            builtins.toJSON (
              csrBinding "kubelet-bootstrap" "system:node-bootstrapper" "system:bootstrappers"
            )
          );
        }
        {
          name = "kubelet-approve-nodeclient.json";
          path = pkgs.writeText "kubelet-approve-nodeclient.json" (
            builtins.toJSON (
              csrBinding "kubelet-approve-nodeclient" "system:certificates.k8s.io:certificatesigningrequests:nodeclient" "system:bootstrappers"
            )
          );
        }
        {
          name = "kubelet-approve-selfnodeclient.json";
          path = pkgs.writeText "kubelet-approve-selfnodeclient.json" (
            builtins.toJSON (
              csrBinding "kubelet-approve-selfnodeclient" "system:certificates.k8s.io:certificatesigningrequests:selfnodeclient" "system:nodes"
            )
          );
        }
        {
          name = "kubelet-approve-selfnodeserver.json";
          path = pkgs.writeText "kubelet-approve-selfnodeserver.json" (
            builtins.toJSON (
              csrBinding "kubelet-approve-selfnodeserver" "system:certificates.k8s.io:certificatesigningrequests:selfnodeserver" "system:nodes"
            )
          );
        }
        {
          name = "kube-proxy-from-nodes.json";
          path = pkgs.writeText "kube-proxy-from-nodes.json" (
            builtins.toJSON (csrBinding "kube-proxy-from-nodes" "system:node-proxier" "system:nodes")
          );
        }
      ];
      adminKubeconfig = config.services.kubernetes.lib.mkKubeConfig "csr-rbac" {
        server = config.services.kubernetes.apiserverAddress;
        caFile = k.cert "ca";
        certFile = k.cert "cluster-admin";
        keyFile = k.key "cluster-admin";
      };
      approveServing = pkgs.writeShellApplication {
        name = "approve-kubelet-serving";
        runtimeInputs = [
          pkgs.kubernetes
          pkgs.jq
          pkgs.openssl
          pkgs.etcd
          pkgs.coreutils
        ];
        runtimeEnv = {
          KUBELET_SERVING_APPROVER = if k.isBootstrap then "1" else "0";
          KUBELET_SERVING_WORKERS = builtins.toJSON (
            lib.mapAttrs (_: member: member.address) (
              lib.filterAttrs (_: member: member.worker) config.cluster.members
            )
          );
          KUBECONFIG = adminKubeconfig;
          ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
          ETCDCTL_CACERT = k.cert "ca";
          ETCDCTL_CERT = k.cert "kube-apiserver-etcd-client";
          ETCDCTL_KEY = k.key "kube-apiserver-etcd-client";
        };
        text = builtins.readFile ../scripts/approve-kubelet-serving.sh;
      };
      checked = {
        active = k.onControl;
        certs = [
          (k.key "service-account")
          (k.cert "ca")
          (k.key "ca")
          (k.cert "kube-controller-manager")
          (k.key "kube-controller-manager")
          (k.cert "kube-controller-manager-client")
          (k.key "kube-controller-manager-client")
        ];
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onControl {
          services.kubernetes.controllerManager = {
            enable = true;
            serviceAccountKeyFile = k.key "service-account";
            rootCaFile = k.cert "ca";
            tlsCertFile = k.cert "kube-controller-manager";
            tlsKeyFile = k.key "kube-controller-manager";
            extraOpts = "--cluster-signing-cert-file=${k.cert "ca"} --cluster-signing-key-file=${k.key "ca"}";
            kubeconfig = {
              caFile = k.cert "ca";
              certFile = k.cert "kube-controller-manager-client";
              keyFile = k.key "kube-controller-manager-client";
            };
          };
          systemd.services.kube-controller-manager.wants = [ "kube-apiserver.service" ];

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
              RestartSec = 5;
              ExecStart = "${pkgs.kubernetes}/bin/kubectl apply --filename ${csrManifests}";
            };
          };
        })
        (lib.mkIf (k.onControl && k.isBootstrap) {
          systemd.services.kubelet-serving-csr-approve = {
            description = "Approve kubelet serving CSRs for workers in cluster.members";
            after = [
              "kube-apiserver.service"
              "kubernetes-pki.service"
              "etcd.service"
              "kubernetes-csr-rbac.service"
            ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe approveServing;
            };
          };
          systemd.timers.kubelet-serving-csr-approve = {
            description = "Approve kubelet serving CSRs for workers in cluster.members";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "30s";
              OnUnitActiveSec = "30s";
              AccuracySec = "5s";
            };
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
