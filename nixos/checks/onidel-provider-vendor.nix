# Builds the onidel provider's go-modules derivation, the vendor tree that vendorHash pins in
# packages/onidel-provider.nix, so a Go module change that leaves the hash stale fails CI's checks
# job on its pull request (the onidel-vendor gate of .github/gates.yml) instead of landing on main.
# The derivation is fixed-output, so its store path follows its name and hash alone, and a store
# that already holds it would skip the build after a source change. The name here carries the
# source's store hash, so each source change builds the modules again and checks the hash.
# Run: bun run check:onidel-vendor
{ pkgs }:
let
  provider = pkgs.callPackage ../packages/onidel-provider.nix { };
  sourceHash = builtins.substring 0 32 (
    builtins.baseNameOf (builtins.unsafeDiscardStringContext "${provider.src}")
  );
in
provider.goModules.overrideAttrs (old: {
  name = "${old.name}-${sourceHash}";
})
