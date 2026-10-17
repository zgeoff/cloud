# The preview service (packages/preview), run by nixpkgs' Bun from its TypeScript source, beside a
# node_modules of its runtime dependencies. The test files, the MSW mocks and the stand-ins stay
# out. The dependencies are the closure of the package's `dependencies` in the workspace's
# bun.lock: each one's npm tarball, fetched at the locked version and checked against the lock's
# sha512, and unpacked flat, so a version the lock nests under another package fails the build.
{
  lib,
  bun,
  fetchurl,
  runCommand,
  writeShellApplication,
}:
let
  root = ../../packages/preview;
  modules = lib.fileset.toSource {
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

  # bun.lock is JSON with trailing commas, which builtins.fromJSON refuses
  lockText = builtins.readFile ../../bun.lock;
  lock = builtins.fromJSON (
    lib.concatMapStrings (part: if builtins.isList part then builtins.head part else part) (
      builtins.split ",([[:space:]]*[]}])" lockText
    )
  );

  # a packages entry: [ "<name>@<version>", "<registry>", { dependencies, … }, "<integrity>" ]
  readLocked =
    parent: name:
    let
      nested = "${parent}/${name}";
    in
    if parent != null && lock.packages ? ${nested} then
      throw "bun.lock nests ${name} under ${parent}, which a flat node_modules cannot hold"
    else
      lock.packages.${name};

  # the runtime closure: each package's `dependencies`, never its peers or its dev dependencies
  collectClosure =
    seen: parent: names:
    lib.foldl' (
      acc: name:
      if acc ? ${name} then
        acc
      else
        let
          entry = readLocked parent name;
          dependencies = builtins.attrNames ((builtins.elemAt entry 2).dependencies or { });
        in
        collectClosure (acc // { ${name} = entry; }) name dependencies
    ) seen names;

  closure = collectClosure { } null (
    builtins.attrNames (lock.workspaces."packages/preview".dependencies or { })
  );

  fetchLocked =
    name: entry:
    let
      id = builtins.head entry;
      version = lib.last (lib.splitString "@" id);
    in
    {
      inherit name;
      tarball = fetchurl {
        url = "https://registry.npmjs.org/${name}/-/${baseNameOf name}-${version}.tgz";
        hash = lib.last entry;
      };
    };

  dependencies = lib.mapAttrsToList fetchLocked closure;

  src = runCommand "preview-service-src" { } ''
    cp -r ${modules} $out
    chmod -R u+w $out
    ${lib.concatMapStrings (dependency: ''
      mkdir -p "$out/node_modules/${dependency.name}"
      tar -xzf ${dependency.tarball} -C "$out/node_modules/${dependency.name}" --strip-components=1
    '') dependencies}
  '';
in
writeShellApplication {
  name = "preview-service";
  runtimeInputs = [ bun ];
  # --no-install: a module missing from node_modules fails the start instead of reaching npm
  text = ''
    exec bun --no-install run ${src}/main.ts
  '';
}
