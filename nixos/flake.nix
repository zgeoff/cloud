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
      url = "github:zgeoff/imp/62b41528";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, disko, imp, ... }:
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

      # bun run test:nixos builds them all. geoffcloud-eval evaluates the host config. Every other
      # check reads ../scripts (scripts/test-lib, and
      # the impd-restore checks the script they rehearse), so they build only with the repo root
      # as the flake's source (path:.?dir=nixos); the impd-restore checks boot one VM each, from
      # checks/test-utils/build-restore-rehearsal.nix, and need KVM. impd-restore-reset tests that
      # rehearsal's own reset
      checks.x86_64-linux.geoffcloud-eval = import ./checks/geoffcloud-eval.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        geoffcloud = self.nixosConfigurations.geoffcloud;
      };
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
      checks.x86_64-linux.impd-restore-saved-failures = import ./checks/impd-restore-saved-failures.nix {
        inherit nixpkgs imp;
      };
      checks.x86_64-linux.impd-restore-reset = import ./checks/impd-restore-reset.nix {
        inherit nixpkgs imp;
      };
    };
}
