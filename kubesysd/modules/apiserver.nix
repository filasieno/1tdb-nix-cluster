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
          assertion =
            !active
            || (
              builtins.isList (cfg.etcdServers or null)
              && cfg.etcdServers != [ ]
              && lib.all c.httpsUrl cfg.etcdServers
            );
          message = "kube-apiserver etcd servers must be a non-empty list of https URLs.";
        }
        {
          assertion = !active || c.absolutePaths (cfg.certs or [ ]);
          message = "kube-apiserver certificate paths must be absolute.";
        }
        {
          assertion = !active || c.port (cfg.bindPort or null);
          message = "kube-apiserver bind port must be an integer from 1 to 65535.";
        }
        {
          assertion =
            !active || (cfg.tokenAuthFile or null) == null || c.absolutePath (cfg.tokenAuthFile or "");
          message = "kube-apiserver tokenAuthFile must be null or an absolute path. The token value is not set in Nix.";
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
      tokenAuthPath = "/run/kubernetes/bootstrap-token-auth.csv";
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
      hasBootstrapToken = sopsHasKey "kubernetes_bootstrap_token";
      tokenScript = pkgs.writeShellApplication {
        name = "kubernetes-bootstrap-token-auth";
        runtimeInputs = [ pkgs.coreutils ];
        runtimeEnv = {
          KUBERNETES_BOOTSTRAP_TOKEN_FILE = bootstrapTokenPath;
          KUBERNETES_TOKEN_AUTH_FILE = tokenAuthPath;
        };
        text = builtins.readFile ../scripts/bootstrap-token-auth.sh;
      };
      checked = {
        active = k.onControl;
        bindPort = 6443;
        etcdServers = lib.mapAttrsToList (
          _: member: "https://${member.address}:${toString config.cluster.etcd.clientPort}"
        ) k.controls;
        certs = [
          (k.cert "kube-apiserver")
          (k.key "kube-apiserver")
          (k.cert "ca")
          (k.cert "service-account")
          (k.key "service-account")
          (k.cert "kube-apiserver-kubelet-client")
          (k.key "kube-apiserver-kubelet-client")
          (k.cert "kube-apiserver-proxy-client")
          (k.key "kube-apiserver-proxy-client")
          (k.cert "kube-apiserver-etcd-client")
          (k.key "kube-apiserver-etcd-client")
        ];
        tokenAuthFile = if k.onControl && hasBootstrapToken then tokenAuthPath else null;
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onControl {
          services.kubernetes.apiserver = {
            enable = true;
            allowPrivileged = true;
            serviceClusterIpRange = config.cluster.kubernetes.serviceCidr;
            tlsCertFile = k.cert "kube-apiserver";
            tlsKeyFile = k.key "kube-apiserver";
            clientCaFile = k.cert "ca";
            serviceAccountKeyFile = k.cert "service-account";
            serviceAccountSigningKeyFile = k.key "service-account";
            kubeletClientCaFile = k.cert "ca";
            kubeletClientCertFile = k.cert "kube-apiserver-kubelet-client";
            kubeletClientKeyFile = k.key "kube-apiserver-kubelet-client";
            proxyClientCertFile = k.cert "kube-apiserver-proxy-client";
            proxyClientKeyFile = k.key "kube-apiserver-proxy-client";
            etcd = {
              servers = lib.mapAttrsToList (
                _: member: "https://${member.address}:${toString config.cluster.etcd.clientPort}"
              ) k.controls;
              certFile = k.cert "kube-apiserver-etcd-client";
              keyFile = k.key "kube-apiserver-etcd-client";
              caFile = k.cert "ca";
            };
          };

          networking.firewall.allowedTCPPorts = [ 6443 ];

          systemd.services.kube-apiserver = {
            after = [
              "kubernetes-pki.service"
              "etcd.service"
            ];
            wants = [
              "kubernetes-pki.service"
              "etcd.service"
            ];
          };
        })
        # Inactive until kubernetes_bootstrap_token exists in the host sops
        # file. No token value is committed. Durin evaluates without it.
        # The CSV maps that token to group system:bootstrappers. This is a
        # static token file, not a Secret, so bootstrapsigner and tokencleaner
        # stay off.
        (lib.mkIf (k.onControl && hasBootstrapToken) {
          sops.secrets.kubernetes-bootstrap-token = {
            key = "kubernetes_bootstrap_token";
            owner = "root";
            group = "root";
            mode = "0400";
            path = bootstrapTokenPath;
            restartUnits = [
              "kubernetes-bootstrap-token.service"
              "kube-apiserver.service"
            ];
          };

          services.kubernetes.apiserver.tokenAuthFile = tokenAuthPath;

          systemd.services.kubernetes-bootstrap-token = {
            description = "Write the kube-apiserver bootstrap token file";
            wantedBy = [ "kube-apiserver.service" ];
            before = [ "kube-apiserver.service" ];
            after = [ "sops-install-secrets.service" ];
            wants = [ "sops-install-secrets.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = 5;
              ExecStart = lib.getExe tokenScript;
            };
          };

          systemd.services.kube-apiserver = {
            after = [ "kubernetes-bootstrap-token.service" ];
            wants = [ "kubernetes-bootstrap-token.service" ];
            requires = [ "kubernetes-bootstrap-token.service" ];
          };
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
