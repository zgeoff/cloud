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
      url = "github:zgeoff/imp/48995873";
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
    };
}
