# The preview service (packages/preview), run by nixpkgs' Bun from its TypeScript source. The
# service imports nothing beyond Bun and Node's built-ins, so the package copies its modules and
# needs no node_modules. The test files, the MSW mocks and the stand-ins stay out.
{
  lib,
  bun,
  writeShellApplication,
}:
let
  root = ../../packages/preview;
  src = lib.fileset.toSource {
    inherit root;
    fileset =
      lib.fileset.difference
        (lib.fileset.fileFilter (file: file.hasExt "ts" && !(lib.hasSuffix ".test.ts" file.name)) root)
        (
          lib.fileset.unions [
            (root + "/mocks")
            (root + "/test-utils")
          ]
        );
  };
in
writeShellApplication {
  name = "preview-service";
  runtimeInputs = [ bun ];
  text = ''
    exec bun run ${src}/main.ts
  '';
}
