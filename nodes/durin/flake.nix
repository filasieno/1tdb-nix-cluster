{
  description = "Durin, a member of the 1tdb cluster.";

  inputs = {
    # Pinned nixos-unstable revision (2026-10-01).
    nixpkgs.url = "github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
    }:
    {
      nixosConfigurations.durin = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit self;
        };
        modules = [
          disko.nixosModules.disko
          ./nix/disko.nix
          ./nix/hardware.nix
          ./nix/default.nix
          sops-nix.nixosModules.sops
        ];
      };
    };
}
