# Public keys of the admin users. Not secrets.
# fabio and roby are age recipients. The Unix accounts are fabio and roberto.
rec {
  fabio = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII9Q9qgKrDtviYMNvx7tqvvdA4Kk2WYh/xRuyJIC/rmX";
  roby = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMO3hl9pVcJ4UcxDlrG/ial3fvxiZfs0rahvWKnNGQ0E";
  devnodes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPOwluyHzqloc0WDo+ER8GMPPbccihyjvr0oU3WOP+xU devnodes-host-access";

  module =
    { lib, pkgs, ... }:
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
          "${fabio} fabio@filasieno.it"
          devnodes
        ];
      };
      users.users.roberto = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.bashInteractive;
        hashedPassword = "!";
        openssh.authorizedKeys.keys = [
          roby
          devnodes
        ];
      };
    };
}
