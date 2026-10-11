{
  description = "The 1tdb channel.";

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
    durin = {
      url = "path:nodes/durin";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
      inputs.sops-nix.follows = "sops-nix";
    };
  };

  outputs =
    { durin, ... }:
    {
      nixosConfigurations = durin.nixosConfigurations;
    };
}
