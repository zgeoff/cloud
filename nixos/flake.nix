{
  description = "NixOS hosts for geoff.cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # imp ships nixosModules.imp from its flake (in progress in zgeoff/imp).
    # Uncomment once it exists, and import it in hosts/geoffcloud.
    # imp.url = "github:zgeoff/imp";
  };

  outputs =
    { nixpkgs, disko, ... }:
    {
      nixosConfigurations.geoffcloud = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./hosts/geoffcloud/configuration.nix
          ./hosts/geoffcloud/disko.nix
        ];
      };
    };
}
