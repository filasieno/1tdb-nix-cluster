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
          assertion = !active || c.httpsUrl (cfg.server or "");
          message = "kube-addon-manager must dial an https API server URL.";
        }
        {
          assertion = !active || c.absolutePaths (cfg.certs or [ ]);
          message = "kube-addon-manager certificate paths must be absolute.";
        }
      ];
    };

  module =
    {
      config,
      lib,
      ...
    }:
    let
      k = import ../lib.nix { inherit config lib; };
      checked = {
        active = k.onControl;
        server = config.services.kubernetes.apiserverAddress;
        certs = [
          (k.cert "ca")
          (k.cert "kube-addon-manager")
          (k.key "kube-addon-manager")
        ];
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onControl {
          services.kubernetes.addonManager.enable = true;
          systemd.services.kube-addon-manager = {
            wants = [ "kube-apiserver.service" ];
            environment.KUBECONFIG = config.services.kubernetes.lib.mkKubeConfig "addon-manager" {
              server = config.services.kubernetes.apiserverAddress;
              caFile = k.cert "ca";
              certFile = k.cert "kube-addon-manager";
              keyFile = k.key "kube-addon-manager";
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
