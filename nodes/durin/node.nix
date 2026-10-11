{ self, ... }:
{
  networking.hostName = "durin";

  nix.settings.experimental-features = [ "nix-command" ];

  # This node's etcd WAL and snapshot disk. Not part of the shared cluster contract.
  kubernetes.etcd.walDirectory = "/var/lib/etcd-wal/wal";
  kubernetes.etcd.backupDirectory = "/data/etcd-backups";

  # containerd state is on the ZFS root. A hosted volume would leave the default overlayfs.
  kubernetes.containerd.snapshotter = "zfs";

  # Path from the distribution root. Not a relative path into shared/.
  sops.defaultSopsFile = self + "/shared/secrets/durin.yaml";
}
