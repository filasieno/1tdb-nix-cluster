{
  config,
  lib,
  pkgs,
  ...
}:
let
  cluster = import ../cluster.nix;
  port = builtins.toString cluster.natGateway.ssh.port;
  configFile = pkgs.writeText "sshd_config" ''
    Port ${port}
    ListenAddress ${cluster.lan.address}
    ListenAddress 127.0.0.1
    AddressFamily inet
    UsePAM no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes
    AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
    HostKey /etc/ssh/ssh_host_ed25519_key
    HostKey /etc/ssh/ssh_host_rsa_key
    ModuliFile ${pkgs.openssh}/etc/ssh/moduli
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
  '';
  # Key files for sshd. The user accounts declare the same keys.
  authorizedKeys = name: {
    "ssh/authorized_keys.d/${name}" = {
      mode = "0444";
      text = lib.concatStringsSep "\n" config.users.users.${name}.openssh.authorizedKeys.keys + "\n";
    };
  };
in
{
  users.groups.sshd = { };
  users.users.sshd = {
    isSystemUser = true;
    group = "sshd";
    description = "SSH privilege separation user";
  };

  environment.etc = authorizedKeys "fabio" // authorizedKeys "roby";

  systemd.tmpfiles.rules = [
    "d /var/empty 0755 root root -"
  ];

  systemd.services.sshd = {
    description = "SSH daemon";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "lan1-ready.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "lan1-ready.service" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.openssh}/bin/ssh-keygen -A";
      ExecStart = "${pkgs.openssh}/bin/sshd -f ${configFile} -D";
      Restart = "always";
      RestartSec = "5s";
      KillMode = "process";
      RuntimeDirectory = "sshd";
      RuntimeDirectoryMode = "0755";
    };
  };
}
