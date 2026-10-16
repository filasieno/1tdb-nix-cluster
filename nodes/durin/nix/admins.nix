# Public keys of the admin users. Not secrets.
# fabio and roby are age recipients. The Unix accounts are fabio and roby.
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
            "roby"
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
        # SHA-512 hash. sshd checks it through pam_unix.
        hashedPassword = "$6$Ic3bC1JKOn/PoeeT$AXSgxHI3ZqVz0HI5RNfGvN5SfRhsVKfESxCkLVhYUIpnn9SxX2PIVz0L8aEYe1pNY9wTLE/YyZ38KemkAM0GK/";
        openssh.authorizedKeys.keys = [
          "${fabio} fabio@filasieno.it"
          devnodes
        ];
      };
      users.users.roby = {
        isNormalUser = true;
        # Keep the uid the account had as "roberto": files on rpool/home
        # are owned by 1001 and users.mutableUsers = false would otherwise
        # pick a fresh uid and orphan them.
        uid = 1001;
        extraGroups = [ "wheel" ];
        shell = pkgs.bashInteractive;
        hashedPassword = "$6$Ic3bC1JKOn/PoeeT$AXSgxHI3ZqVz0HI5RNfGvN5SfRhsVKfESxCkLVhYUIpnn9SxX2PIVz0L8aEYe1pNY9wTLE/YyZ38KemkAM0GK/";
        openssh.authorizedKeys.keys = [
          roby
          devnodes
        ];
      };
    };
}
