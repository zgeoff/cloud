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
      url = "github:zgeoff/imp/ce3012c5";
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
          ./hosts/geoffcloud/configuration.nix
          ./hosts/geoffcloud/disko.nix
        ];
      };

      # atc's daemon, for a later host change (docs/plans/atc-gateway.md)
      nixosModules.atc-daemon = ./modules/atc-daemon.nix;
      checks.x86_64-linux.atc-daemon = import ./checks/atc-daemon.nix { inherit nixpkgs; };
    };
}
