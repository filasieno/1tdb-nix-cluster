# Support commands. Each shell body under ../shell is wrapped once.
# Daemon starters that are not files in shell/ are here too, so the units
# do not call writeShellApplication or writeShellScript themselves.
{ pkgs, lib }:
let
  cluster = import ./cluster.nix;
  apiDomain = import ./api-domain.nix;
  kubeconfig = import ./kubeconfig.nix;
  shell = ../shell;

  # Platform realm client used by kubectl oidc-login. The ID token audience
  # is this client id. Groups in the token are Keycloak group names; the
  # prefix below is what RoleBinding subjects must use (oidc:admin).
  # The apiserver fetches JWKS from the issuer URL, so this host must be
  # able to open https://keycloak.1tdb.io (public DNS and NAT hairpin).
  oidc = {
    issuerUrl = "https://keycloak.1tdb.io/realms/Platform";
    clientId = "kubernetes";
    usernameClaim = "preferred_username";
    usernamePrefix = "oidc:";
    groupsClaim = "groups";
    groupsPrefix = "oidc:";
  };

  clusterAdminKubeconfig = kubeconfig {
    inherit pkgs;
    name = "cluster-admin";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "cluster-admin";
    key = cluster.key "cluster-admin";
  };

  ciliumChart = pkgs.fetchurl {
    url = "https://helm.cilium.io/cilium-1.20.4.tgz";
    hash = "sha256-UFq/+DhYEd8alJd2/ELp8QaXmJozKsyG1uiTPvy4Ve0=";
  };
  # kube-proxy is not installed. Cilium owns ClusterIP, NodePort, and masquerade.
  # The Istio-facing knobs stay on even though Flux installs Istio later:
  # socket LB must not rewrite connects inside a pod network namespace, or a
  # sidecar never sees the traffic; cni.exclusive must stay false so Istio's
  # CNI config is not renamed away; gatewayAPI and Envoy stay off so Cilium
  # does not claim Gateway resources Istio will own.
  # devices is only the bridge. The BMC USB gadget must not get the BPF datapath.
  ciliumValues = pkgs.writeText "cilium-values.yaml" ''
    kubeProxyReplacement: "true"
    k8sServiceHost: "${cluster.lan.address}"
    k8sServicePort: "${builtins.toString cluster.natGateway.apiserver.port}"
    waitForKubeProxy: false
    ipam:
      mode: kubernetes
    routingMode: tunnel
    tunnelProtocol: vxlan
    devices: "${cluster.lan.interface}"
    socketLB:
      enabled: true
      hostNamespaceOnly: true
    cni:
      exclusive: false
    bpf:
      masquerade: true
    enableIPv4Masquerade: true
    # BPF host routing skips pod netfilter, so ztunnel never SNATs kubelet
    # probes off 169.254.7.127 and NetworkPolicy drops them as world.
    enableHostLegacyRouting: true
    l7Proxy: false
    envoy:
      enabled: false
    gatewayAPI:
      enabled: false
    ingressController:
      enabled: false
    envoyConfig:
      enabled: false
    # Hubble's server is already on (chart default). Relay, UI, and the
    # Prometheus listeners are not, and their mTLS material is minted by this
    # Helm release. cilium-install owns the release and re-applies these
    # values, so Flux cannot add them. metricsService publishes the agent and
    # operator ports; the ServiceMonitors live in 1tdb-cluster because the
    # Prometheus Operator CRDs are not installed when this chart first runs.
    prometheus:
      enabled: true
      metricsService: true
    operator:
      replicas: 1
      prometheus:
        enabled: true
        metricsService: true
    hubble:
      metrics:
        enabled:
          - dns
          - drop
          - tcp
          - flow
          - icmp
          - http
      relay:
        enabled: true
        prometheus:
          enabled: true
      ui:
        enabled: true
  '';

  controllerKubeconfig = kubeconfig {
    inherit pkgs;
    name = "kube-controller-manager";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "kube-controller-manager-client";
    key = cluster.key "kube-controller-manager-client";
  };
  schedulerKubeconfig = kubeconfig {
    inherit pkgs;
    name = "kube-scheduler";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "kube-scheduler-client";
    key = cluster.key "kube-scheduler-client";
  };
  kubeletKubeconfig = kubeconfig {
    inherit pkgs;
    name = "kubelet";
    server = cluster.apiServer;
    ca = cluster.cert "ca";
    cert = cluster.cert "kubelet-client";
    key = cluster.key "kubelet-client";
  };
  kubeletConfig = pkgs.writeText "kubelet-config.json" (
    builtins.toJSON {
      apiVersion = "kubelet.config.k8s.io/v1beta1";
      kind = "KubeletConfiguration";
      address = cluster.lan.address;
      port = 10250;
      authentication = {
        x509.clientCAFile = cluster.cert "ca";
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
      clusterDomain = "cluster.local";
      clusterDNS = [ cluster.clusterDns ];
      # The host /etc/resolv.conf is the systemd-resolved stub (127.0.0.53).
      # Handing that to pods makes CoreDNS forward to itself and crash on
      # the loop check; give pods the real upstream list instead.
      resolvConf = "/run/systemd/resolve/resolv.conf";
      tlsCertFile = cluster.cert "kubelet";
      tlsPrivateKeyFile = cluster.key "kubelet";
    }
  );
in
{
  pki = pkgs.writeShellApplication {
    name = "kubernetes-pki";
    runtimeInputs = [
      pkgs.openssl
      pkgs.coreutils
    ];
    runtimeEnv = {
      KUBERNETES_SECRETS_DIR = cluster.secrets;
      KUBERNETES_HOSTNAME = cluster.host;
      KUBERNETES_CLUSTER_NAME = cluster.name;
      KUBERNETES_SERVICE_IP = cluster.serviceIp;
      KUBERNETES_LAN_ADDRESS = cluster.lan.address;
      KUBERNETES_API_DOMAINS = lib.concatStringsSep "," apiDomain.names;
    };
    text = builtins.readFile (shell + "/pki.sh");
  };

  adminKubeconfig = pkgs.writeShellApplication {
    name = "kubernetes-admin-kubeconfig";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      KUBERNETES_API_SERVER = cluster.publicApiServer;
      OIDC_ISSUER_URL = oidc.issuerUrl;
      OIDC_CLIENT_ID = oidc.clientId;
    };
    text = builtins.readFile (shell + "/admin-kubeconfig.sh");
  };

  etcdSnapshot = pkgs.writeShellApplication {
    name = "etcd-snapshot";
    runtimeInputs = [
      pkgs.etcd
      pkgs.coreutils
    ];
    runtimeEnv = {
      ETCD_BACKUP_DIR = cluster.backupDirectory;
      ETCD_ENDPOINT = cluster.etcdClient;
      ETCD_CERT = cluster.cert "kube-apiserver-etcd-client";
      ETCD_KEY = cluster.key "kube-apiserver-etcd-client";
      ETCD_CACERT = cluster.cert "ca";
    };
    text = builtins.readFile (shell + "/etcd-snapshot.sh");
  };

  approveKubeletServing = pkgs.writeShellApplication {
    name = "approve-kubelet-serving";
    runtimeInputs = [
      pkgs.kubectl
      pkgs.jq
      pkgs.openssl
      pkgs.etcd
      pkgs.coreutils
    ];
    runtimeEnv = {
      KUBELET_SERVING_APPROVER = "1";
      # A file rather than an inline JSON string: writeShellApplication
      # exports runtimeEnv as single-quoted literals, and shellcheck rejects
      # quotes inside them (SC2089/SC2090).
      KUBELET_SERVING_WORKERS_FILE = pkgs.writeText "kubelet-serving-workers.json" (
        builtins.toJSON { ${cluster.host} = cluster.lan.address; }
      );
      KUBECONFIG = clusterAdminKubeconfig;
      ETCDCTL_ENDPOINTS = cluster.etcdClient;
      ETCDCTL_CACERT = cluster.cert "ca";
      ETCDCTL_CERT = cluster.cert "kube-apiserver-etcd-client";
      ETCDCTL_KEY = cluster.key "kube-apiserver-etcd-client";
    };
    text = builtins.readFile (shell + "/approve-kubelet-serving.sh");
  };

  installCilium = pkgs.writeShellApplication {
    name = "install-cilium";
    runtimeInputs = [
      pkgs.kubernetes-helm
      pkgs.kubectl
      pkgs.etcd
      pkgs.coreutils
    ];
    runtimeEnv = {
      CILIUM_CHART = ciliumChart;
      CILIUM_VALUES = ciliumValues;
      KUBECONFIG = clusterAdminKubeconfig;
      ETCDCTL_ENDPOINTS = cluster.etcdClient;
      ETCDCTL_CACERT = cluster.cert "ca";
      ETCDCTL_CERT = cluster.cert "kube-apiserver-etcd-client";
      ETCDCTL_KEY = cluster.key "kube-apiserver-etcd-client";
    };
    text = builtins.readFile (shell + "/install-cilium.sh");
  };

  vaultTls = pkgs.writeShellApplication {
    name = "vault-tls";
    runtimeInputs = [
      pkgs.openssl
      pkgs.coreutils
    ];
    runtimeEnv = {
      VAULT_TLS_DIR = "/var/lib/vault/tls";
      VAULT_TLS_HOSTNAME = cluster.host;
      VAULT_TLS_LAN_ADDRESS = cluster.lan.address;
      VAULT_TLS_DOMAINS = lib.concatStringsSep "," apiDomain.names;
    };
    text = builtins.readFile (shell + "/vault-tls.sh");
  };

  vaultInit = pkgs.writeShellApplication {
    name = "vault-init";
    runtimeInputs = [
      pkgs.vault
      pkgs.age
      pkgs.jq
      pkgs.coreutils
      pkgs.systemd
      # The vault CLI resolves its token-helper config path through the
      # home directory, and falls back to getent when $HOME is unset,
      # as it is in a systemd unit without User=.
      pkgs.getent
    ];
    runtimeEnv = {
      VAULT_ADDR = "http://127.0.0.1:8200";
      VAULT_RECOVERY_RECIPIENTS = lib.concatStringsSep "\n" cluster.recoveryRecipients;
      VAULT_ROOT_TOKEN_FILE = "/var/lib/vault-bootstrap/root.token";
    };
    text = builtins.readFile (shell + "/vault-init.sh");
  };

  vaultPlatformAdmin = pkgs.writeShellApplication {
    name = "vault-platform-admin";
    runtimeInputs = [
      pkgs.vault
      pkgs.kubectl
      pkgs.jq
      pkgs.etcd
      pkgs.coreutils
      pkgs.getent
    ];
    runtimeEnv = {
      VAULT_ADDR = "http://127.0.0.1:8200";
      KUBECONFIG = clusterAdminKubeconfig;
      VAULT_KUBERNETES_HOST = "https://127.0.0.1:6443";
      VAULT_KUBERNETES_CA = cluster.cert "ca";
      VAULT_KUBERNETES_ISSUER = "https://kubernetes.default.svc";
      VAULT_PLATFORM_NAMESPACE = "vault-platform-admin";
      VAULT_PLATFORM_SERVICE_ACCOUNT = "vault-platform-admin-sa";
      VAULT_PLATFORM_TOKEN_SECRET = "vault-platform-admin-sa-token";
      VAULT_PLATFORM_ROLE = "vault-platform-admin";
      VAULT_PLATFORM_POLICY = "vault-platform-admin";
      VAULT_ROOT_TOKEN_FILE = "/var/lib/vault-bootstrap/root.token";
      ETCDCTL_ENDPOINTS = cluster.etcdClient;
      ETCDCTL_CACERT = cluster.cert "ca";
      ETCDCTL_CERT = cluster.cert "kube-apiserver-etcd-client";
      ETCDCTL_KEY = cluster.key "kube-apiserver-etcd-client";
    };
    text = builtins.readFile (shell + "/vault-platform-admin.sh");
  };

  vaultSealCredential = pkgs.writeShellApplication {
    name = "vault-seal-credential";
    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
    ];
    runtimeEnv.VAULT_CREDENTIAL_NAME = (import ./azure.nix).credentialName;
    text = builtins.readFile (shell + "/vault-seal-credential.sh");
  };

  # The WAL pool mountpoint itself must belong to etcd: the WAL is first
  # written as <walDirectory>.tmp in the parent and renamed into place.
  etcdPrepare = pkgs.writeShellScript "etcd-prepare" ''
    install -d -m 0700 -o etcd -g etcd /var/lib/etcd ${cluster.walMount} ${cluster.walDirectory}
  '';

  # WAL files mean this node has already joined; forcing "new" then makes
  # etcd refuse to come back after the first boot. The member directory is
  # not that signal: a crashed first bootstrap leaves member/snap/db behind
  # with no WAL, and "existing" would then try to join a cluster that never
  # formed. This mirrors etcd's own member-initialized check (wal.Exist on
  # the dedicated WAL dir).
  etcdStart = pkgs.writeShellScript "etcd-start" ''
    set -euo pipefail
    shopt -s nullglob
    wals=(${cluster.walDirectory}/*.wal)
    if (( ''${#wals[@]} > 0 )); then
      export ETCD_INITIAL_CLUSTER_STATE=existing
    else
      export ETCD_INITIAL_CLUSTER_STATE=new
    fi
    exec ${pkgs.etcd}/bin/etcd
  '';

  # Request-header auth is what aggregated API servers (metrics-server) use to
  # see the original user. The proxy certificate is CN=front-proxy-client,
  # signed by the same CA as every other client, so allowed-names is required:
  # without it kube-apiserver refuses to start, and any client certificate
  # could impersonate. Without these flags, kubectl top is authorized as
  # front-proxy-client and denied.
  kubeApiserver = pkgs.writeShellScript "kube-apiserver" ''
    exec ${pkgs.kubernetes}/bin/kube-apiserver \
      --allow-privileged=true \
      --anonymous-auth=false \
      --authorization-mode=Node,RBAC \
      --enable-admission-plugins=NodeRestriction \
      --advertise-address=${cluster.lan.address} \
      --bind-address=0.0.0.0 \
      --secure-port=${builtins.toString cluster.natGateway.apiserver.port} \
      --client-ca-file=${cluster.cert "ca"} \
      --tls-cert-file=${cluster.cert "kube-apiserver"} \
      --tls-private-key-file=${cluster.key "kube-apiserver"} \
      --kubelet-certificate-authority=${cluster.cert "ca"} \
      --kubelet-preferred-address-types=InternalIP,Hostname \
      --kubelet-client-certificate=${cluster.cert "kube-apiserver-kubelet-client"} \
      --kubelet-client-key=${cluster.key "kube-apiserver-kubelet-client"} \
      --proxy-client-cert-file=${cluster.cert "kube-apiserver-proxy-client"} \
      --proxy-client-key-file=${cluster.key "kube-apiserver-proxy-client"} \
      --requestheader-client-ca-file=${cluster.cert "ca"} \
      --requestheader-allowed-names=front-proxy-client \
      --requestheader-username-headers=X-Remote-User \
      --requestheader-group-headers=X-Remote-Group \
      --requestheader-extra-headers-prefix=X-Remote-Extra- \
      --etcd-servers=${cluster.etcdClient} \
      --etcd-cafile=${cluster.cert "ca"} \
      --etcd-certfile=${cluster.cert "kube-apiserver-etcd-client"} \
      --etcd-keyfile=${cluster.key "kube-apiserver-etcd-client"} \
      --service-cluster-ip-range=${cluster.serviceCidr} \
      --service-account-issuer=https://kubernetes.default.svc \
      --service-account-key-file=${cluster.cert "service-account"} \
      --service-account-signing-key-file=${cluster.key "service-account"} \
      --api-audiences=https://kubernetes.default.svc \
      --storage-backend=etcd3 \
      --oidc-issuer-url=${oidc.issuerUrl} \
      --oidc-client-id=${oidc.clientId} \
      --oidc-username-claim=${oidc.usernameClaim} \
      --oidc-username-prefix=${oidc.usernamePrefix} \
      --oidc-groups-claim=${oidc.groupsClaim} \
      --oidc-groups-prefix=${oidc.groupsPrefix}
  '';

  kubeControllerManager = pkgs.writeShellScript "kube-controller-manager" ''
    exec ${pkgs.kubernetes}/bin/kube-controller-manager \
      --allocate-node-cidrs=true \
      --bind-address=127.0.0.1 \
      --cluster-cidr=${cluster.podCidr} \
      --service-cluster-ip-range=${cluster.serviceCidr} \
      --cluster-signing-cert-file=${cluster.cert "ca"} \
      --cluster-signing-key-file=${cluster.key "ca"} \
      --root-ca-file=${cluster.cert "ca"} \
      --service-account-private-key-file=${cluster.key "service-account"} \
      --tls-cert-file=${cluster.cert "kube-controller-manager"} \
      --tls-private-key-file=${cluster.key "kube-controller-manager"} \
      --kubeconfig=${controllerKubeconfig} \
      --leader-elect=true \
      --use-service-account-credentials
  '';

  kubeScheduler = pkgs.writeShellScript "kube-scheduler" ''
    exec ${pkgs.kubernetes}/bin/kube-scheduler \
      --bind-address=127.0.0.1 \
      --kubeconfig=${schedulerKubeconfig} \
      --leader-elect=true
  '';

  kubeletPrepare = pkgs.writeShellScript "kubelet-prepare" ''
    install -d -m 0755 /opt/cni/bin /etc/cni/net.d /var/lib/kubernetes
    shopt -s nullglob
    for bin in ${pkgs.cni-plugins}/bin/*; do
      ln -sfn "$bin" "/opt/cni/bin/$(basename "$bin")"
    done
  '';

  kubelet = pkgs.writeShellScript "kubelet" ''
    exec ${pkgs.kubernetes}/bin/kubelet \
      --config=${kubeletConfig} \
      --hostname-override=${cluster.host} \
      --node-ip=${cluster.lan.address} \
      --kubeconfig=${kubeletKubeconfig} \
      --root-dir=/var/lib/kubernetes
  '';
}
