{
  description = "NixOS hosts for geoff.cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # imp's host module (zgeoff/imp docs/guides/nixos.md); pinned by flake.lock
    imp = {
      url = "github:zgeoff/imp/fc19d43d";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, disko, imp, ... }:
    {
      nixosConfigurations.geoffcloud = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          imp.nixosModules.imp
          ./modules/impd-local-health.nix
          ./modules/atc-daemon.nix
          ./hosts/geoffcloud/configuration.nix
          ./hosts/geoffcloud/disko.nix
        ];
      };

      # atc's daemon (docs/plans/atc-gateway.md), and the release binary geoffcloud runs it from
      nixosModules.atc-daemon = ./modules/atc-daemon.nix;
      packages.x86_64-linux = rec {
        atc = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/atc.nix { };
        atc-interactive = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/atc-interactive.nix {
          inherit atc;
        };
      };
      checks.x86_64-linux.atc-daemon = import ./checks/atc-daemon.nix { inherit nixpkgs; };
      checks.x86_64-linux.impd-local-health = import ./checks/impd-local-health.nix { inherit nixpkgs; };
    };
}
