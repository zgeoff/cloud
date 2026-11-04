# The Bun release that a Dockerfile's one oven/bun stage pinned by digest runs, looked up by the stage's Bun version
# in releases, an attribute set of Bun versions to { digest; hash; }: the image digest the stage
# pins and the hash of the release's bun-linux-x64.zip. Gives { version; hash; } when releases
# holds the version at the stage's digest, and { error; } otherwise, with a message that names the
# version or the count of stages. nixos/checks/test-utils-check.nix tests it.
{ lib }:
releases: dockerfile:
let
  stages = lib.filter (stage: stage != null) (
    map (builtins.match "FROM oven/bun:([^@ ]+)@(sha256:[0-9a-f]+)( .*)?") (
      lib.splitString "\n" dockerfile
    )
  );
  version = builtins.elemAt (builtins.head stages) 0;
  digest = builtins.elemAt (builtins.head stages) 1;
  release = releases.${version} or null;
in
if lib.length stages != 1 then
  {
    error = "the Dockerfile has ${toString (lib.length stages)} oven/bun stages pinned by digest, not 1";
  }
else if release == null then
  { error = "no release of Bun ${version}: add its image digest and the hash of its zip"; }
else if release.digest != digest then
  { error = "the Dockerfile pins Bun ${version} at ${digest}, not at ${release.digest}"; }
else
  {
    inherit version;
    inherit (release) hash;
  }
