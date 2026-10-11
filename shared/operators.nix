{
  lib,
  pkgs,
  ...
}:
let
  recipients = import ./recipients.nix;
in
{
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  security.sudo.extraRules = lib.mkForce [
    {
      users = [
        "fabio"
        "roberto"
      ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
  users.users.fabio = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "${recipients.fabio} fabio@filasieno.it"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOwluyHzqloc0WDo+ER8GMPPbccihyjvr0oU3WOP+xU devnodes-host-access"
    ];
  };
  users.users.roberto = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMO3hl9pVcJ4UcxDlrG/ial3fvxiZfs0rahvWKnNGQ0E roby@batman"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOwluyHzqloc0WDo+ER8GMPPbccihyjvr0oU3WOP+xU devnodes-host-access"
    ];
  };

  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
    };
  };
}
