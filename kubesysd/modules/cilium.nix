{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
      active = cfg.active or false;
      install = cfg.install or false;
    in
    {
      assertions = [
        {
          assertion = !active || c.unsigned (cfg.replicas or null);
          message = "Cilium operator replicas must be a non-negative integer.";
        }
        {
          assertion = !active || c.httpsUrl (cfg.chartUrl or "");
          message = "The Cilium chart URL must be https.";
        }
        {
          assertion = !active || (c.port (cfg.healthPort or null) && c.port (cfg.vxlanPort or null));
          message = "Cilium health and VXLAN ports must be integers from 1 to 65535.";
        }
        {
          assertion = !install || c.httpsUrl (cfg.etcdEndpoint or "");
          message = "cilium-install must dial etcd over https.";
        }
        {
          assertion = !install || c.absolutePaths (cfg.certs or [ ]);
          message = "cilium-install certificate paths must be absolute.";
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
      controlCount = lib.length (lib.attrNames k.controls);
      chartUrl = "https://helm.cilium.io/cilium-1.20.2.tgz";
      chart = pkgs.fetchurl {
        url = chartUrl;
        hash = "sha256-sq/Ye391+HX5KhRVnxT1m3uru0edlo4/1iWiC/MOwg4=";
      };
      replicas = if controlCount >= 2 then 2 else 1;
      values = pkgs.writeText "cilium-values.yaml" ''
        operator:
          replicas: ${toString replicas}
        kubeProxyReplacement: "false"
        ipam:
          mode: kubernetes
        routingMode: tunnel
        tunnelProtocol: vxlan
        socketLB:
          hostNamespaceOnly: true
        cni:
          exclusive: false
        bpf:
          masquerade: false
        l7Proxy: false
        envoy:
          enabled: false
        gatewayAPI:
          enabled: false
        ingressController:
          enabled: false
        envoyConfig:
          enabled: false
      '';
      installCilium = pkgs.writeShellApplication {
        name = "install-cilium";
        runtimeInputs = [
          pkgs.kubernetes-helm
          pkgs.kubectl
          pkgs.etcd
        ];
        runtimeEnv = {
          CILIUM_CHART = chart;
          CILIUM_VALUES = values;
          ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
          ETCDCTL_CACERT = k.cert "ca";
          ETCDCTL_CERT = k.cert "kube-apiserver-etcd-client";
          ETCDCTL_KEY = k.key "kube-apiserver-etcd-client";
        };
        text = builtins.readFile ../scripts/install-cilium.sh;
      };
      checked = {
        active = k.onControl || k.onWorker;
        install = k.onControl;
        inherit replicas chartUrl;
        healthPort = 4240;
        vxlanPort = 8472;
        etcdEndpoint = "https://127.0.0.1:2379";
        certs = [
          (k.cert "ca")
          (k.cert "kube-apiserver-etcd-client")
          (k.key "kube-apiserver-etcd-client")
        ];
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf (k.onControl || k.onWorker) {
          services.kubernetes.flannel.enable = lib.mkForce false;
        })
        (lib.mkIf k.onWorker {
          environment.etc."cni/net.d".enable = lib.mkForce false;
          systemd.tmpfiles.settings."10-cni-conf"."/etc/cni/net.d".d = {
            user = "root";
            group = "root";
            mode = "0755";
          };
          networking.firewall.allowedTCPPorts = [ 4240 ];
          networking.firewall.allowedUDPPorts = [ 8472 ];
        })
        (lib.mkIf k.onControl {
          systemd.services.cilium-install = {
            description = "Install Cilium into the cluster";
            wantedBy = [ "multi-user.target" ];
            after = [
              "kube-apiserver.service"
              "etcd.service"
            ]
            ++ lib.optional k.onWorker "kubelet.service";
            wants = [
              "kube-apiserver.service"
            ]
            ++ lib.optional k.onWorker "kubelet.service";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = 10;
              TimeoutStartSec = 900;
              ExecStart = lib.getExe installCilium;
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
