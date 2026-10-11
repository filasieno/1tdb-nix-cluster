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
          assertion = !active || c.absolutePath (cfg.secrets or "");
          message = "Kubernetes PKI secretsDir must be an absolute path.";
        }
        {
          assertion = !active || c.unsigned (cfg.generation or null);
          message = "cluster.kubernetes.pkiGeneration must be a non-negative integer.";
        }
        {
          assertion = !active || c.hostname (cfg.host or "");
          message = "Kubernetes PKI requires a lowercase DNS hostname.";
        }
        {
          assertion = !active || cfg.packageName == "kubernetes";
          message = "kubesysd requires pkgs.kubernetes (upstream), not k3s.";
        }
        {
          assertion = !active || c.absolutePath (cfg.caFile or "");
          message = "The Kubernetes CA path must be absolute.";
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
      cfg = config.cluster.kubernetes;

      csv = xs: lib.concatStringsSep "," xs;
      dnsSans = names: map (name: "DNS:${name}") names;
      ipSans = addrs: map (addr: "IP:${addr}") addrs;

      # This host's name, apiHost, and cluster.name. unique drops repeats.
      apiserverNames = lib.unique (
        [
          k.host
          cfg.apiHost
          "localhost"
          "kubernetes"
          "kubernetes.default"
          "kubernetes.default.svc"
          "kubernetes.default.svc.cluster.local"
        ]
        ++ lib.optional (
          config.cluster.name != k.host && config.cluster.name != cfg.apiHost
        ) config.cluster.name
      );
      controlAddresses = lib.mapAttrsToList (_: member: member.address) k.controls;
      nodeAddress = if k.me == null then "" else k.me.address;
      apiserverAddresses = lib.unique (
        [
          "127.0.0.1"
          cfg.serviceIp
        ]
        ++ controlAddresses
        ++ lib.optional (nodeAddress != "" && nodeAddress != "127.0.0.1") nodeAddress
        ++ lib.optional (cfg.apiAddress != "" && cfg.apiAddress != "127.0.0.1") cfg.apiAddress
      );
      localAddresses = lib.unique (
        [ "127.0.0.1" ] ++ lib.optional (nodeAddress != "" && nodeAddress != "127.0.0.1") nodeAddress
      );
      apiserverSans = csv (dnsSans apiserverNames ++ ipSans apiserverAddresses);
      etcdSans = csv (
        dnsSans [
          "etcd.local"
          "etcd.cluster.local"
          k.host
        ]
        ++ ipSans localAddresses
      );
      kubeletSans = csv (dnsSans [ k.host ] ++ ipSans localAddresses);
      controllerSans = csv (dnsSans [ k.host ] ++ ipSans [ "127.0.0.1" ]);
      stamp = builtins.hashString "sha256" (
        builtins.toJSON {
          generation = cfg.pkiGeneration;
          host = k.host;
          inherit
            apiserverSans
            etcdSans
            kubeletSans
            ;
        }
      );

      leafFiles = name: [
        "${name}.pem"
        "${name}-key.pem"
      ];
      required = [
        "ca.pem"
      ]
      ++ lib.optionals k.onControl (
        [ "ca-key.pem" ]
        ++ lib.concatMap leafFiles [
          "kube-apiserver"
          "kube-apiserver-kubelet-client"
          "kube-apiserver-proxy-client"
          "kube-apiserver-etcd-client"
          "cluster-admin"
          "etcd"
          "kube-controller-manager"
          "kube-controller-manager-client"
          "kube-scheduler-client"
          "kube-addon-manager"
          "service-account"
        ]
      )
      ++ lib.optionals (k.onWorker && k.onControl) (
        lib.concatMap leafFiles [
          "kubelet"
          "kubelet-client"
          "kube-proxy-client"
        ]
      );

      pkiScript = pkgs.writeShellApplication {
        name = "kubernetes-pki";
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        runtimeEnv = {
          KUBERNETES_SECRETS_DIR = k.secrets;
          KUBERNETES_HOSTNAME = k.host;
          KUBERNETES_BOOTSTRAP = if k.isBootstrap then "1" else "0";
          KUBERNETES_ROLE_CONTROL = if k.onControl then "1" else "0";
          KUBERNETES_ROLE_WORKER = if k.onWorker then "1" else "0";
          KUBERNETES_PKI_STAMP = stamp;
          KUBERNETES_APISERVER_SANS = apiserverSans;
          KUBERNETES_ETCD_SANS = etcdSans;
          KUBERNETES_KUBELET_SANS = kubeletSans;
          KUBERNETES_CONTROLLER_SANS = controllerSans;
          KUBERNETES_API_SERVER = config.services.kubernetes.apiserverAddress;
          KUBERNETES_BOOTSTRAP_TOKEN_FILE =
            if config.kubernetes.kubelet.bootstrapTokenFile == null then
              ""
            else
              config.kubernetes.kubelet.bootstrapTokenFile;
          KUBERNETES_REQUIRED = lib.concatStringsSep "\n" required;
        };
        text = builtins.readFile ../scripts/pki.sh;
      };
      adminKubeconfig = pkgs.writeShellApplication {
        name = "kubernetes-admin-kubeconfig";
        runtimeInputs = [ pkgs.coreutils ];
        runtimeEnv.KUBERNETES_API_SERVER = config.services.kubernetes.apiserverAddress;
        text = builtins.readFile ../scripts/admin-kubeconfig.sh;
      };
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
        active = k.known;
        secrets = k.secrets;
        generation = cfg.pkiGeneration;
        host = k.host;
        packageName = lib.getName pkgs.kubernetes;
        caFile = k.cert "ca";
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.known {
          services.kubernetes.easyCerts = lib.mkForce false;
          services.kubernetes.caFile = k.cert "ca";

          systemd.tmpfiles.rules = [
            "d ${k.secrets} 0750 root kubernetes -"
          ];

          systemd.services.kubernetes-pki = {
            description = "Issue Kubernetes certificates. Only the bootstrap control member may mint the CA.";
            wantedBy = [ "multi-user.target" ];
            before = [
              "etcd.service"
              "kube-apiserver.service"
              "kubelet.service"
            ];
            after = [
              "systemd-tmpfiles-setup.service"
              "sops-install-secrets.service"
            ];
            wants = [ "sops-install-secrets.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe pkiScript;
            };
          };

          system.activationScripts.kubernetes-admin-kubeconfig.text = ''
            ${lib.getExe adminKubeconfig}
          '';
        })
        # Inactive until kubernetes_ca_cert / kubernetes_ca_key exist in the
        # host sops file. No ciphertext is committed for them. The bootstrap
        # host keeps minting on disk while these stay off. Workers may receive
        # the certificate only. The key stays on control members.
        (lib.mkIf ((k.onControl || k.onWorker) && sopsHasKey "kubernetes_ca_cert") {
          sops.secrets.kubernetes-ca = {
            key = "kubernetes_ca_cert";
            owner = "root";
            group = "kubernetes";
            mode = "0444";
            path = k.cert "ca";
            restartUnits = [ "kubernetes-pki.service" ];
          };
        })
        (lib.mkIf (k.onControl && sopsHasKey "kubernetes_ca_key") {
          sops.secrets.kubernetes-ca-key = {
            key = "kubernetes_ca_key";
            owner = "root";
            group = "kubernetes";
            mode = "0440";
            path = k.key "ca";
            restartUnits = [ "kubernetes-pki.service" ];
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
