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
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      nixos-anywhere,
    }:
    let
      lib = nixpkgs.lib;
      check = import ./kubesysd/cluster/check.nix;
      member = {
        imports = [
          (import ./kubesysd/cluster/module.nix)
          ./shared/cluster.nix
          ./shared/operators.nix
          ./shared/member.nix
          sops-nix.nixosModules.sops
          (import ./kubesysd/modules/node.nix { inherit check; })
          (import ./kubesysd/vault/module.nix { inherit check; })
        ];
      };
    in
    {
      nixosConfigurations.durin = lib.nixosSystem {
        specialArgs = {
          inherit self;
        };
        modules = [
          disko.nixosModules.disko
          ./nodes/durin/disko.nix
          ./nodes/durin/hardware.nix
          ./nodes/durin/node.nix
          member
        ];
      };

      packages = lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (
        system:
        lib.optionalAttrs (nixos-anywhere.packages ? ${system} && nixos-anywhere.packages.${system} ? default) {
          nixos-anywhere = nixos-anywhere.packages.${system}.default;
        }
      );
    };
}
