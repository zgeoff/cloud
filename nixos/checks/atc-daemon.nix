# Builds a minimal system with services.atc-daemon on and a stand-in binary, so the
# module stays valid while no host imports it. Run: nix build ./nixos#checks.x86_64-linux.atc-daemon
{ nixpkgs }:
let
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ../modules/atc-daemon.nix
      (
        { pkgs, ... }:
        {
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          services.atc-daemon = {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
          };
        }
      )
    ];
  };
in
system.config.systemd.units."atc-daemon.service".unit
