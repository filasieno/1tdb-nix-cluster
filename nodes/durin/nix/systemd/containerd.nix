{
  config,
  lib,
  pkgs,
  ...
}:
let
  # One Artifact Keeper remote per upstream. The host path is the repository
  # key, so docker.io/library/alpine is pulled from
  # artifact.1tdb.io/v2/dockerhub/library/alpine. server stays the real
  # upstream and is used when the cache is down. Image names in manifests
  # stay unchanged.
  mirrors = {
    "docker.io" = {
      repo = "dockerhub";
      upstream = "https://registry-1.docker.io";
    };
    "ghcr.io" = {
      repo = "ghcr";
      upstream = "https://ghcr.io";
    };
    "quay.io" = {
      repo = "quay";
      upstream = "https://quay.io";
    };
    "registry.k8s.io" = {
      repo = "k8s";
      upstream = "https://registry.k8s.io";
    };
    "gcr.io" = {
      repo = "gcr";
      upstream = "https://gcr.io";
    };
    "mcr.microsoft.com" = {
      repo = "mcr";
      upstream = "https://mcr.microsoft.com";
    };
    "public.ecr.aws" = {
      repo = "ecr-public";
      upstream = "https://public.ecr.aws";
    };
    "reg.kyverno.io" = {
      repo = "kyverno";
      upstream = "https://reg.kyverno.io";
    };
    "registry.istio.io" = {
      repo = "istio";
      upstream = "https://registry.istio.io";
    };
  };
  configFile = pkgs.writeText "containerd.toml" ''
    version = 2
    root = "/var/lib/containerd"
    state = "/run/containerd"

    [grpc]
      address = "/run/containerd/containerd.sock"

    [plugins."io.containerd.grpc.v1.cri"]
      sandbox_image = "registry.k8s.io/pause:3.10"

      [plugins."io.containerd.grpc.v1.cri".cni]
        bin_dir = "/opt/cni/bin"
        conf_dir = "/etc/cni/net.d"

      [plugins."io.containerd.grpc.v1.cri".containerd]
        snapshotter = "zfs"
        default_runtime_name = "crun"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun.options]
            BinaryName = "${pkgs.crun}/bin/crun"
            SystemdCgroup = true

    [plugins."io.containerd.cri.v1.images"]
      snapshotter = "zfs"

      [plugins."io.containerd.cri.v1.images".registry]
        config_path = "/etc/containerd/certs.d"

    # containerd 2 migrates version = 2, including io.containerd.grpc.v1.cri.
    # The transfer unpack path is not part of that migration.
    [plugins."io.containerd.transfer.v1.local"]
      [[plugins."io.containerd.transfer.v1.local".unpack_config]]
        platform = "linux/amd64"
        snapshotter = "zfs"
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /etc/cni/net.d 0755 root root -"
    "d /opt/cni/bin 0755 root root -"
  ];

  environment.etc = lib.mapAttrs' (host: mirror:
    lib.nameValuePair "containerd/certs.d/${host}/hosts.toml" {
      text = ''
        server = "${mirror.upstream}"

        [host."https://artifact.1tdb.io/v2/${mirror.repo}"]
          capabilities = ["pull", "resolve"]
          override_path = true
          dial_timeout = "5s"
      '';
    }
  ) mirrors;

  # disko declares data/containerd. On a pool that was created before that
  # dataset existed, create it before the mount unit runs.
  #
  # DefaultDependencies would add After=basic.target. This unit is Before=
  # var-lib-containerd.mount, and that mount is Before=local-fs.target, which
  # is ordered before basic.target. The result is an ordering cycle. systemd
  # breaks it by deleting the mount job, so containerd and the kubelet never
  # start. Keep this oneshot in the early-boot window, after the pool import
  # and before the mount.
  systemd.services.containerd-dataset = {
    description = "Create the containerd dataset on the data pool";
    requiredBy = [ "var-lib-containerd.mount" ];
    before = [
      "var-lib-containerd.mount"
      "shutdown.target"
    ];
    after = [ "zfs-import.target" ];
    requires = [ "zfs-import.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "containerd-dataset" ''
        set -euo pipefail
        if ! ${config.boot.zfs.package}/bin/zfs list -H data/containerd >/dev/null 2>&1; then
          ${config.boot.zfs.package}/bin/zfs create \
            -o mountpoint=legacy \
            -o compression=zstd \
            data/containerd
        fi
      '';
    };
  };

  systemd.services.containerd = {
    description = "containerd";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "local-fs.target"
      "dbus.service"
      "var-lib-containerd.mount"
    ];
    unitConfig.RequiresMountsFor = "/var/lib/containerd";
    path = [
      pkgs.containerd
      pkgs.crun
      pkgs.runc
      pkgs.iptables
      config.boot.zfs.package
    ];
    serviceConfig = {
      Type = "notify";
      Delegate = "yes";
      KillMode = "process";
      Restart = "always";
      RestartSec = "10s";
      LimitNPROC = "infinity";
      LimitCORE = "infinity";
      TasksMax = "infinity";
      OOMScoreAdjust = "-999";
      ExecStartPre = pkgs.writeShellScript "containerd-prepare" ''
        install -d -m 0755 /var/lib/containerd/io.containerd.snapshotter.v1.zfs
      '';
      ExecStart = "${pkgs.containerd}/bin/containerd --config ${configFile}";
      RuntimeDirectory = "containerd";
      RuntimeDirectoryPreserve = "yes";
    };
  };
}
