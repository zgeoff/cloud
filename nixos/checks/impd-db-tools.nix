# Checks the impd database tools package (nixos/packages/impd-db-tools) in the build sandbox:
# the argument checks copy-impd-db-host makes before it touches anything. The copy itself needs
# Podman and the imp-host container, so the impd-restore rehearsal runs it in its VM. Each case
# runs on its own, in a fresh directory, with the tool under env -i and a HOME and TMPDIR of its
# own, as a bats test, which reports each case and fails the check when
# any case fails.
# Run: bun run test:nixos impd-db-tools
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  tools = pkgs.callPackage ../packages/impd-db-tools { };
  copy = "${tools.copy}/bin/copy-impd-db-host";

  cases = [
    {
      title = "it copy-impd-db-host refuses a label with a slash before it makes anything";
      script = ''
        mkdir home tmp
        status=0

        env -i PATH=/var/empty HOME="$PWD/home" TMPDIR="$PWD/tmp" ${copy} ../imp-0.29.0 > stdout 2> stderr || status=$?

        assert_equal "$status" 1
        diff -u /dev/null stdout
        # the tool's stderr
        assert_equal "$(cat stderr)" "the label may hold only letters, digits, '.', '_' and '-'"
        # the files it made
        assert_equal "$(ls -A home)$(ls -A tmp)" ""
      '';
    }
    {
      title = "it copy-impd-db-host prints its usage without a label";
      script = ''
        mkdir home tmp
        status=0

        env -i PATH=/var/empty HOME="$PWD/home" TMPDIR="$PWD/tmp" ${copy} > stdout 2> stderr || status=$?

        assert_equal "$status" 1
        diff -u /dev/null stdout
        # bash names the tool and the line of the failed expansion in the file
        # writeShellApplication wrote
        # the tool's stderr
        assert_equal "$(cat stderr)" "${copy}: line 22: 1: usage: copy-impd-db-host <label>, such as imp-0.29.0-pre-0.30.0"
      '';
    }
  ];
in
pkgs.runCommand "impd-db-tools-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.coreutils
      pkgs.diffutils
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    # fixed, so the modes the cases assert do not depend on the builder's umask
    umask 022
    bats --timing --print-output-on-failure ${pkgs.writeText "impd-db-tools.bats" (renderCases cases)}
    touch $out
  ''
