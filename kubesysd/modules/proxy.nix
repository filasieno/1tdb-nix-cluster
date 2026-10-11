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
          message = "kube-proxy certificate paths must be absolute.";
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
      kubeletClientCurrent = "/var/lib/kubelet/pki/kubelet-client-current.pem";
      checked = {
        active = k.onWorker;
        certs =
          if k.onWorker && !k.onControl then
            [
              (k.cert "ca")
              kubeletClientCurrent
              "${k.secrets}/kubelet-client.pem"
              "${k.secrets}/kubelet-client-key.pem"
            ]
          else
            [
              (k.cert "ca")
              (k.cert "kube-proxy-client")
              (k.key "kube-proxy-client")
            ];
      };
      proxyRun = pkgs.writeShellApplication {
        name = "kube-proxy-run";
        runtimeInputs = [
          pkgs.kubernetes
          pkgs.iptables
          pkgs.conntrack-tools
          pkgs.coreutils
        ];
        runtimeEnv = {
          KUBERNETES_SECRETS_DIR = k.secrets;
          KUBERNETES_HOSTNAME = k.host;
          KUBE_PROXY_CA = k.cert "ca";
          KUBE_PROXY_SERVER = config.services.kubernetes.apiserverAddress;
          KUBE_PROXY_CLUSTER_CIDR = config.cluster.kubernetes.podCidr;
          KUBELET_CLIENT_CURRENT = kubeletClientCurrent;
        };
        text = ''
          secrets=$KUBERNETES_SECRETS_DIR
          current=$KUBELET_CLIENT_CURRENT
          if [[ -s $current ]]; then
            cert=$current
            key=$current
          elif [[ -s $secrets/kubelet-client.pem && -s $secrets/kubelet-client-key.pem ]]; then
            cert=$secrets/kubelet-client.pem
            key=$secrets/kubelet-client-key.pem
          else
            echo "kube-proxy: kubelet client certificate is not present yet" >&2
            exit 1
          fi
          cfg=$(mktemp)
          chmod 0600 "$cfg"
          cat >"$cfg" <<EOF
          apiVersion: v1
          kind: Config
          clusters:
          - name: local
            cluster:
              certificate-authority: $KUBE_PROXY_CA
              server: $KUBE_PROXY_SERVER
          contexts:
          - name: local
            context:
              cluster: local
              user: kube-proxy
          current-context: local
          users:
          - name: kube-proxy
            user:
              client-certificate: $cert
              client-key: $key
          EOF
          exec kube-proxy \
            --bind-address=0.0.0.0 \
            --cluster-cidr="$KUBE_PROXY_CLUSTER_CIDR" \
            --hostname-override="$KUBERNETES_HOSTNAME" \
            --kubeconfig="$cfg"
        '';
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf (k.onWorker && k.onControl) {
          services.kubernetes.proxy = {
            enable = true;
            kubeconfig = {
              caFile = k.cert "ca";
              certFile = k.cert "kube-proxy-client";
              keyFile = k.key "kube-proxy-client";
            };
          };
          systemd.services.kube-proxy = {
            after = [
              "kubernetes-pki.service"
              "network-online.target"
              "kube-apiserver.service"
            ];
            wants = [
              "kubernetes-pki.service"
              "network-online.target"
              "kube-apiserver.service"
            ];
          };
        })
        (lib.mkIf (k.onWorker && !k.onControl) {
          services.kubernetes.proxy = {
            enable = true;
            kubeconfig = {
              caFile = k.cert "ca";
              certFile = kubeletClientCurrent;
              keyFile = kubeletClientCurrent;
            };
          };
          systemd.services.kube-proxy = {
            after = [
              "kubernetes-pki.service"
              "kubelet.service"
              "network-online.target"
            ];
            wants = [
              "kubernetes-pki.service"
              "kubelet.service"
              "network-online.target"
            ];
            serviceConfig.ExecStart = lib.mkForce (lib.getExe proxyRun);
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
