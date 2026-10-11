# by-id paths taken from the running host on 2026-10-10.
# The two Samsung MZ7L3480HCHQ drives are a mirrored rpool. Each has its own
# ESP so either disk can boot. The Optane SSDPEL1K375GA is the etcdwal pool.
# The Samsung 990 PRO 2TB is the data pool.
{
  disko.devices = {
    disk = {
      samsung-mz7l3480-a = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7L3480HCHQ-00A07_S664NN0YA04245";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "umask=0077"
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };

      samsung-mz7l3480-b = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7L3480HCHQ-00A07_S664NN0YA04255";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";
                mountOptions = [
                  "umask=0077"
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };

      # Dedicated etcd WAL pool. Not a root disk and not an rpool SLOG.
      intel-optane = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-INTEL_SSDPEL1K375GA_PHKM23010138375A";
        content = {
          type = "gpt";
          partitions = {
            wal = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "etcdwal";
              };
            };
          };
        };
      };

      samsung-990pro = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_with_Heatsink_2TB_S7DRNJ0YB12728K";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "data";
              };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";
        mode = "mirror";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "zstd";
          atime = "off";
          xattr = "sa";
          acltype = "posixacl";
          canmount = "off";
          mountpoint = "none";
        };
        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.compression = "zstd";
          };
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
          };
          var = {
            type = "zfs_fs";
            mountpoint = "/var";
          };
        };
      };

      etcdwal = {
        type = "zpool";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "off";
          atime = "off";
          recordsize = "16K";
          logbias = "latency";
          sync = "standard";
          xattr = "sa";
          canmount = "off";
          mountpoint = "none";
          primarycache = "metadata";
        };
        datasets.etcd = {
          type = "zfs_fs";
          mountpoint = "/var/lib/etcd-wal";
          options = {
            compression = "off";
            atime = "off";
            recordsize = "16K";
            logbias = "latency";
            sync = "standard";
            primarycache = "metadata";
          };
        };
      };

      data = {
        type = "zpool";
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          compression = "zstd";
          atime = "off";
          xattr = "sa";
          acltype = "posixacl";
          canmount = "off";
          mountpoint = "none";
        };
        datasets.store = {
          type = "zfs_fs";
          mountpoint = "/data";
        };
        # Image layers. The SATA mirror holds the root filesystem; this
        # dataset is the 990 PRO. containerd-dataset.service creates it
        # when an already-installed pool does not have it yet.
        datasets.containerd = {
          type = "zfs_fs";
          mountpoint = "/var/lib/containerd";
          options.compression = "zstd";
        };
      };
    };
  };
}
