{ check }:
let
  validateOptions =
    { lib }:
    cfg:
    let
      c = check { inherit lib; };
      active = cfg.active or false;
    in
    {
      assertions = [
        {
          assertion = !active || c.absolutePaths (cfg.certs or [ ]);
          message = "kubelet certificate paths must be absolute.";
        }
        {
          assertion = !active || c.port (cfg.port or null);
          message = "The kubelet port must be an integer from 1 to 65535.";
        }
        {
          assertion = !active || (cfg.bootstrapTokenFile or null) == null || c.absolutePath (cfg.bootstrapTokenFile or "");
          message = "kubernetes.kubelet.bootstrapTokenFile must be null or an absolute path of a sops secret. The token value is not set in Nix.";
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
      tokenFile = config.kubernetes.kubelet.bootstrapTokenFile;
      bootstrapTokenPath = "/run/secrets/kubernetes-bootstrap-token";
      sopsFile = config.sops.defaultSopsFile;
      sopsText =
        let
          existing =
            if sopsFile == null then
              null
            else if builtins.isPath sopsFile then
              sopsFile
            else if builtins.isString sopsFile && builtins.pathExists sopsFile then
              sopsFile
            else
              null;
        in
        if existing == null then "" else builtins.readFile existing;
      sopsHasKey = key: lib.hasPrefix "${key}:" sopsText || lib.hasInfix "\n${key}:" sopsText;
      checked = {
        active = k.onWorker;
        port = 10250;
        bootstrapTokenFile = tokenFile;
        certs =
          if k.onControl then
            [
              (k.cert "ca")
              (k.cert "kubelet")
              (k.key "kubelet")
              (k.cert "kubelet-client")
              (k.key "kubelet-client")
            ]
          else
            [
              (k.cert "ca")
              "${k.secrets}/kubelet-bootstrap.kubeconfig"
            ];
      };
      kubeletBootstrapConfig = pkgs.writeText "kubelet-config-bootstrap.json" (
        builtins.toJSON {
          apiVersion = "kubelet.config.k8s.io/v1beta1";
          kind = "KubeletConfiguration";
          address = "0.0.0.0";
          port = 10250;
          authentication = {
            x509.clientCAFile = k.cert "ca";
            webhook = {
              enabled = true;
              cacheTTL = "10s";
            };
          };
          authorization.mode = "Webhook";
          cgroupDriver = "systemd";
          hairpinMode = "hairpin-veth";
          registerNode = true;
          containerRuntimeEndpoint = "unix:///run/containerd/containerd.sock";
          healthzPort = 10248;
          healthzBindAddress = "127.0.0.1";
          clusterDomain = config.services.kubernetes.kubelet.clusterDomain;
          clusterDNS = config.services.kubernetes.kubelet.clusterDns;
          serverTLSBootstrap = true;
          rotateCertificates = true;
        }
      );
      kubeletStaticConfig = pkgs.writeText "kubelet-config-static.json" (
        builtins.toJSON {
          apiVersion = "kubelet.config.k8s.io/v1beta1";
          kind = "KubeletConfiguration";
          address = "0.0.0.0";
          port = 10250;
          authentication = {
            x509.clientCAFile = k.cert "ca";
            webhook = {
              enabled = true;
              cacheTTL = "10s";
            };
          };
          authorization.mode = "Webhook";
          cgroupDriver = "systemd";
          hairpinMode = "hairpin-veth";
          registerNode = true;
          containerRuntimeEndpoint = "unix:///run/containerd/containerd.sock";
          healthzPort = 10248;
          healthzBindAddress = "127.0.0.1";
          clusterDomain = config.services.kubernetes.kubelet.clusterDomain;
          clusterDNS = config.services.kubernetes.kubelet.clusterDns;
          tlsCertFile = k.cert "kubelet";
          tlsPrivateKeyFile = k.key "kubelet";
        }
      );
      nodeIpArg = if k.me == null || k.me.address == "127.0.0.1" then "" else "--node-ip=${k.me.address}";
      kubeletRun = pkgs.writeShellApplication {
        name = "kubelet-run";
        runtimeInputs = [ pkgs.kubernetes ];
        runtimeEnv = {
          KUBERNETES_HOSTNAME = k.host;
          KUBERNETES_SECRETS_DIR = k.secrets;
          KUBELET_CONFIG_STATIC = kubeletStaticConfig;
          KUBELET_CONFIG_BOOTSTRAP = kubeletBootstrapConfig;
          KUBELET_NODE_IP_ARG = nodeIpArg;
        };
        text = ''
          secrets=$KUBERNETES_SECRETS_DIR
          node_ip=()
          if [[ -n $KUBELET_NODE_IP_ARG ]]; then
            node_ip+=("$KUBELET_NODE_IP_ARG")
          fi
          if [[ -s $secrets/kubelet.pem && -s $secrets/kubelet-key.pem && -s $secrets/kubelet-client.pem && -s $secrets/kubelet-client-key.pem && -s $secrets/kubelet.kubeconfig ]]; then
            exec kubelet \
              --config="$KUBELET_CONFIG_STATIC" \
              --hostname-override="$KUBERNETES_HOSTNAME" \
              --kubeconfig="$secrets/kubelet.kubeconfig" \
              --root-dir=/var/lib/kubernetes \
              "''${node_ip[@]}"
          fi
          exec kubelet \
            --config="$KUBELET_CONFIG_BOOTSTRAP" \
            --hostname-override="$KUBERNETES_HOSTNAME" \
            --bootstrap-kubeconfig="$secrets/kubelet-bootstrap.kubeconfig" \
            --kubeconfig=/var/lib/kubernetes/kubelet/kubeconfig \
            --cert-dir=/var/lib/kubelet/pki \
            --root-dir=/var/lib/kubernetes \
            "''${node_ip[@]}"
        '';
      };
    in
    {
      options.kubernetes.kubelet.bootstrapTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute path of a sops secret file whose contents are the kubelet
          bootstrap token. The token value is not set in this repository.
          When kubernetes_bootstrap_token is present in this host's sops file
          and this member is a worker and not a control member, the module
          declares that secret and this option defaults to its path.
          A worker that is not a control member writes this path into the
          bootstrap kubeconfig as tokenFile. When it is null, kubernetes-pki
          still writes the client key and CSR from ca.pem and does not read ca-key.pem.
        '';
      };

      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onWorker {
          # The API server dials kubelet on 10250.
          networking.firewall.allowedTCPPorts = [ 10250 ];

          services.kubernetes.kubelet = {
            enable = true;
            clientCaFile = k.cert "ca";
            # roles is unused. An empty role list makes NixOS mark the kubelet unschedulable.
            unschedulable = lib.mkForce false;
            cni.packages = lib.mkForce [ pkgs.cni-plugins ];
          };

          systemd.services.kubelet = {
            after = [
              "kubernetes-pki.service"
              "containerd.service"
            ];
            wants = [
              "kubernetes-pki.service"
              "containerd.service"
            ]
            ++ lib.optional k.onControl "kube-apiserver.service";
          };
        })
        (lib.mkIf (k.onWorker && k.onControl) {
          services.kubernetes.kubelet = {
            tlsCertFile = k.cert "kubelet";
            tlsKeyFile = k.key "kubelet";
            kubeconfig = {
              caFile = k.cert "ca";
              certFile = k.cert "kubelet-client";
              keyFile = k.key "kubelet-client";
            };
          };
        })
        (lib.mkIf (k.onWorker && !k.onControl) {
          services.kubernetes.kubelet = {
            extraConfig = {
              serverTLSBootstrap = true;
              rotateCertificates = true;
            };
          };

          systemd.tmpfiles.rules = [
            "d /var/lib/kubernetes/kubelet 0750 root kubernetes -"
            "d /var/lib/kubelet/pki 0750 root root -"
          ];

          systemd.services.kubelet = {
            unitConfig.ConditionPathExists = k.cert "ca";
            serviceConfig.ExecStart = lib.mkForce (lib.getExe kubeletRun);
          };
        })
        (lib.mkIf (k.onWorker && !k.onControl && sopsHasKey "kubernetes_bootstrap_token") {
          sops.secrets.kubernetes-bootstrap-token = {
            key = "kubernetes_bootstrap_token";
            owner = "root";
            group = "root";
            mode = "0400";
            path = bootstrapTokenPath;
            restartUnits = [ "kubelet.service" ];
          };
          kubernetes.kubelet.bootstrapTokenFile = lib.mkDefault bootstrapTokenPath;
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
