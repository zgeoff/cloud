# Evaluates a NixOS system of one module and one config, apart from any host's config, for the
# module checks: given the module and the config (such as { services.atc-daemon = { ... }; }),
# it returns the evaluated system, as lib.nixosSystem does. Beside them it sets only what any
# system needs to evaluate: a state version, no boot loader and a root filesystem.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
module: config:
import "${pkgs.path}/nixos/lib/eval-config.nix" {
  system = "x86_64-linux";
  modules = [
    module
    {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
    }
    config
  ];
}
