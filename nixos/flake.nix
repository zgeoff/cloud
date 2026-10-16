{
  description = "NixOS hosts for geoff.cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # imp's host module (zgeoff/impz docs/guides/nixos.md); pinned by flake.lock
    imp = {
      url = "github:zgeoff/impz/bcd5cd4f";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      imp,
      ...
    }:
    {
      nixosConfigurations.geoffcloud = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          imp.nixosModules.imp
          ./modules/impd-local-health.nix
          ./modules/atc-daemon.nix
          ./modules/cloud-host-firewall.nix
          ./modules/onepassword-connect-relay.nix
          ./modules/preview.nix
          ./modules/tank-cloud.nix
          ./hosts/geoffcloud/configuration.nix
          ./hosts/geoffcloud/disko.nix
        ];
      };

      # bun run test:nixos builds them all. geoffcloud-eval evaluates the host config, and exposure
      # compares its firewall with the exposure registry (packages/topology/exposure.json), and
      # imp-pin compares the imp input's release with its imp-host image tag. Every other
      # check reads ../test-support/shell (checks/test-utils/build-shell-lib-source.nix), so they
      # build only with the repo root as the flake's source (path:.?dir=nixos); the impd-restore
      # checks boot one VM each, from checks/test-utils/build-restore-rehearsal.nix, and need KVM.
      # impd-restore-reset tests that rehearsal's own reset. tank-cloud-unlock boots a VM of its
      # own, and needs KVM too
      checks.x86_64-linux.geoffcloud-eval = import ./checks/geoffcloud-eval.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        geoffcloud = self.nixosConfigurations.geoffcloud;
      };
      checks.x86_64-linux.exposure = import ./checks/exposure.nix {
        inherit nixpkgs imp;
        geoffcloud = self.nixosConfigurations.geoffcloud;
      };
      checks.x86_64-linux.imp-pin = import ./checks/imp-pin.nix {
        inherit nixpkgs imp;
        geoffcloud = self.nixosConfigurations.geoffcloud;
      };
      checks.x86_64-linux.atc-daemon = import ./checks/atc-daemon.nix { inherit nixpkgs imp; };
      checks.x86_64-linux.cloud-host-firewall = import ./checks/cloud-host-firewall.nix {
        inherit nixpkgs imp;
      };
      checks.x86_64-linux.preview = import ./checks/preview.nix { inherit nixpkgs imp; };
      checks.x86_64-linux.onepassword-connect-relay = import ./checks/onepassword-connect-relay.nix {
        inherit nixpkgs imp;
      };
      checks.x86_64-linux.impd-db-tools = import ./checks/impd-db-tools.nix { inherit nixpkgs imp; };
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
      checks.x86_64-linux.tank-cloud-unlock = import ./checks/tank-cloud-unlock.nix {
        inherit nixpkgs;
        geoffcloud = self.nixosConfigurations.geoffcloud;
      };
    };
}
