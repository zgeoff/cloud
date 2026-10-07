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
      url = "github:zgeoff/imp/2679ab06";
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
      # bun run test:nixos builds them all. Every check reads ../scripts (scripts/test-lib, and
      # impd-restore and impd-restore-seams the script they rehearse), so they build only with the
      # repo root as the flake's source (path:.?dir=nixos); those two boot one VM each, from
      # checks/test-utils/build-restore-rehearsal.nix, and need KVM
      checks.x86_64-linux.atc-daemon = import ./checks/atc-daemon.nix { inherit nixpkgs imp; };
      checks.x86_64-linux.test-utils = import ./checks/test-utils-check.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit imp;
      };
      checks.x86_64-linux.impd-local-health = import ./checks/impd-local-health.nix {
        inherit nixpkgs imp;
      };
      checks.x86_64-linux.impd-restore = import ./checks/impd-restore.nix { inherit nixpkgs imp; };
      checks.x86_64-linux.impd-restore-seams = import ./checks/impd-restore-seams.nix {
        inherit nixpkgs imp;
      };
    };
}
