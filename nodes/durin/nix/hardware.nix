{
  lib,
  pkgs,
  ...
}:
let
  cluster = import ./cluster.nix;
in
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
    # Intel I210, both onboard LAN ports. See nodes/durin/doc/node.md.
    "igb"
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
  fileSystems."/var/lib/containerd".neededForBoot = lib.mkForce false;

  networking.useNetworkd = true;
  # Only the 10-lan1 network below configures an address. Today eno2 and the
  # BMC USB gadget (enp14s0u10u2c2) both take DHCP, and eno2 adds a second
  # default route. Neither gets an address after this install.
  networking.useDHCP = false;
  networking.nameservers = [ cluster.lan.dns ];
  # Admin kubeconfigs use these names. On this host they are the LAN address,
  # so kubectl works before public DNS is delegated.
  networking.hosts.${cluster.lan.address} = (import ./api-domain.nix).names;
  # Rename the I210 whose permanent address is cluster.lan.mac. Matching the
  # name eno1 is not enough: the AST2600 USB gadget and LAN2 are also ethernet
  # devices, and a kernel name can move. The address is static so the NAT
  # gateway forwards always land on this card.
  systemd.network.links."10-lan1" = {
    matchConfig.PermanentMACAddress = cluster.lan.mac;
    linkConfig.Name = cluster.lan.interface;
  };
  systemd.network.networks."10-lan1" = {
    matchConfig.PermanentMACAddress = cluster.lan.mac;
    address = [ "${cluster.lan.address}/${toString cluster.lan.prefix}" ];
    gateway = [ cluster.lan.gateway ];
    dns = [ cluster.lan.dns ];
    linkConfig.RequiredForOnline = "routable";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
  };

  # The firewall opens ports by the name lan1. If the MAC match misses, that
  # name never appears and every allow rule matches nothing. sshd, the API
  # server, the kubelet, and Vault require this unit, so a missed rename
  # stops those services instead of booting with the ports closed.
  systemd.services.lan1-ready = {
    description = "Pinned address is configured on lan1";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-networkd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.iproute2
      pkgs.gnugrep
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "lan1-ready" ''
        set -euo pipefail
        for _ in $(seq 1 30); do
          if ip -4 addr show dev ${cluster.lan.interface} 2>/dev/null \
            | grep -q "inet ${cluster.lan.address}/"; then
            exit 0
          fi
          sleep 1
        done
        echo "${cluster.lan.interface} does not have ${cluster.lan.address}; the MAC rename did not apply" >&2
        exit 1
      '';
    };
  };

  system.stateVersion = "26.11";
}
