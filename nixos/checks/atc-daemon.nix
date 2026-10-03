# Builds a minimal system with services.atc-daemon on and a stand-in binary, so the
# module stays valid apart from any host's config. Run: nix build ./nixos#checks.x86_64-linux.atc-daemon
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
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        }
      )
    ];
  };
in
system.config.systemd.units."atc-daemon.service".unit
