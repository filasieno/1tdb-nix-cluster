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
          message = "kube-scheduler certificate paths must be absolute.";
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
        certs = [
          (k.cert "ca")
          (k.cert "kube-scheduler-client")
          (k.key "kube-scheduler-client")
        ];
      };
    in
    {
      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } checked).assertions;
        }
        (lib.mkIf k.onControl {
          services.kubernetes.scheduler = {
            enable = true;
            kubeconfig = {
              caFile = k.cert "ca";
              certFile = k.cert "kube-scheduler-client";
              keyFile = k.key "kube-scheduler-client";
            };
          };
          systemd.services.kube-scheduler.wants = [ "kube-apiserver.service" ];
        })
      ];
    };
in
{
  __functor = _: module;
  inherit validateOptions;
}
