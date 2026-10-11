let
  validateOptions =
    { lib }:
    cfg:
    {
      assertions = [
        {
          assertion = cfg.snapshotter == "overlayfs" || cfg.snapshotter == "zfs";
          message = "kubernetes.containerd.snapshotter must be overlayfs or zfs.";
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
      cfg = config.kubernetes.containerd;
    in
    {
      options.kubernetes.containerd.snapshotter = lib.mkOption {
        type = lib.types.enum [
          "overlayfs"
          "zfs"
        ];
        default = "overlayfs";
        description = "containerd snapshotter. Set zfs when the containerd state directory is a ZFS dataset.";
      };

      config = lib.mkMerge [
        {
          assertions = (validateOptions { inherit lib; } { snapshotter = cfg.snapshotter; }).assertions;
        }
        (lib.mkIf k.onWorker {
          virtualisation.containerd.enable = true;
          virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".containerd = {
            snapshotter = cfg.snapshotter;
            default_runtime_name = "crun";
            runtimes.crun = {
              runtime_type = "io.containerd.runc.v2";
              options = {
                BinaryName = "${pkgs.crun}/bin/crun";
                SystemdCgroup = true;
              };
            };
          };
          virtualisation.containerd.settings.plugins."io.containerd.cri.v1.images".snapshotter = cfg.snapshotter;
          virtualisation.containerd.settings.plugins."io.containerd.transfer.v1.local".unpack_config = [
            {
              platform = "linux/amd64";
              snapshotter = cfg.snapshotter;
            }
          ];
          systemd.services.containerd.path = [ pkgs.crun ];
          systemd.tmpfiles.settings."10-containerd-zfs" = lib.mkIf (cfg.snapshotter == "zfs") {
            "/var/lib/containerd/io.containerd.snapshotter.v1.zfs".d = {
              user = "root";
              group = "root";
              mode = "0755";
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
