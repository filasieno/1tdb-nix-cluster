{
  lib,
  pkgs,
  ...
}:
{
  nixpkgs.hostPlatform = "x86_64-linux";

  # Stable ZFS host id. Do not change this after rpool, etcdwal, or data is created.
  networking.hostId = "4e8025bc";
  time.timeZone = "Europe/Rome";

  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    mirroredBoots = [
      {
        devices = [ "nodev" ];
        path = "/boot";
        efiSysMountPoint = "/boot";
      }
      {
        devices = [ "nodev" ];
        path = "/boot-fallback";
        efiSysMountPoint = "/boot-fallback";
      }
    ];
  };
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "xhci_pci"
    "uas"
    "usbhid"
    "usb_storage"
  ];

  boot.supportedFilesystems = [ "zfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [
    "etcdwal"
    "data"
  ];
  services.zfs.autoScrub.enable = true;

  boot.kernelPackages = pkgs.linuxPackages;
  hardware.cpu.amd.updateMicrocode = true;
  powerManagement.cpuFreqGovernor = "performance";
  services.irqbalance.enable = true;
  boot.kernelParams = [ "transparent_hugepage=madvise" ];
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "fs.file-max" = 2097152;
    "net.core.somaxconn" = 4096;
    "net.core.netdev_max_backlog" = 16384;
    "net.ipv4.tcp_max_syn_backlog" = 8192;
    "net.ipv4.tcp_fin_timeout" = 15;
    "net.ipv4.ip_local_port_range" = "10240 65535";
  };

  fileSystems."/var/lib/etcd-wal".neededForBoot = lib.mkForce false;
  fileSystems."/data".neededForBoot = lib.mkForce false;

  networking.useNetworkd = true;
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en* eth*";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    linkConfig.RequiredForOnline = "routable";
  };

  system.stateVersion = "26.11";
}
