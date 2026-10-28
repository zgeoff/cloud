# The partial Onidel provider (provider/), built from the repo's Go module for the host's scheduled
# drift check (modules/drift-check.nix). The check never calls Onidel's API, but the Pulumi engine
# starts each provider that the state records, so the binary has to be there. Only the Go sources
# and the module files reach the build, so a test fixture or a spec change leaves the hash as it is.
{
  lib,
  buildGoModule,
}:
let
  root = ../../provider;
in
buildGoModule {
  pname = "pulumi-resource-onidel";
  version = "0.1.0";

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/go.mod")
      (root + "/go.sum")
      (lib.fileset.fileFilter (file: file.hasExt "go" && !(lib.hasSuffix "_test.go" file.name)) root)
    ];
  };

  vendorHash = "sha256-ikD+4QeynUEHd62p5rlXt7DGCfism44nMoZBEh9pcHo=";
  subPackages = [ "cmd/pulumi-resource-onidel" ];
  env.CGO_ENABLED = "0";

  meta = {
    description = "The partial Onidel Pulumi provider";
    mainProgram = "pulumi-resource-onidel";
    platforms = [ "x86_64-linux" ];
  };
}
