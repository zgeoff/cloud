# Builds the onidel provider's go-modules derivation, the vendor tree that vendorHash pins in
# packages/onidel-provider.nix, so a Go module change that leaves the hash stale fails CI's checks
# job on its pull request (the onidel-vendor gate of .github/gates.yml) instead of landing on main.
# Run: bun run check:onidel-vendor
{ pkgs }: (pkgs.callPackage ../packages/onidel-provider.nix { }).goModules
