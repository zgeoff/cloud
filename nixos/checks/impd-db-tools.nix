# Checks the impd database tools package (nixos/packages/impd-db-tools) in the build sandbox:
# the argument checks copy-impd-db-host makes before it touches anything. The copy itself needs
# Podman and the imp-host container, so the impd-restore rehearsal runs it in its VM. Each case
# runs on its own, in a fresh directory, with the tool under env -i and a HOME and TMPDIR of its
# own, under test-support/shell/run-cases.sh, which reports each case and fails the check when
# any case fails.
# Run: bun run test:nixos impd-db-tools
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
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

        assert_equals 1 "$status" "the exit status"
        assert_files_equal /dev/null stdout
        assert_equals "the label may hold only letters, digits, '.', '_' and '-'" "$(cat stderr)" "the tool's stderr"
        assert_equals "" "$(ls -A home)$(ls -A tmp)" "the files it made"
      '';
    }
    {
      title = "it copy-impd-db-host prints its usage without a label";
      script = ''
        mkdir home tmp
        status=0

        env -i PATH=/var/empty HOME="$PWD/home" TMPDIR="$PWD/tmp" ${copy} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the exit status"
        assert_files_equal /dev/null stdout
        # bash names the tool and the line of the failed expansion in the file
        # writeShellApplication wrote
        assert_equals "${copy}: line 22: 1: usage: copy-impd-db-host <label>, such as imp-0.29.0-pre-0.30.0" \
          "$(cat stderr)" "the tool's stderr"
      '';
    }
  ];
in
pkgs.runCommand "impd-db-tools-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    # fixed, so the modes the cases assert do not depend on the builder's umask
    umask 022
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "impd-db-tools-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
