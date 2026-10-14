# The shell test helpers the checks read from test-support/shell, as one store directory that
# holds those files and no other: run-cases.sh, the assert_* helpers and wait-for.sh, with the
# suites of run-cases.sh and the assert_* helpers, which test-utils-check.nix runs. Every other
# file in test-support/shell stays out, so an edit to a stand-in the checks never read changes no
# check's derivation. scripts/needs-nixos-checks.sh lists the same files as inputs of the checks:
# a file added here is added there too.
{ lib }:
lib.fileset.toSource {
  root = ../../../test-support/shell;
  fileset = lib.fileset.unions [
    ../../../test-support/shell/run-cases.sh
    ../../../test-support/shell/test-run-cases.sh
    ../../../test-support/shell/assert-equals.sh
    ../../../test-support/shell/test-assert-equals.sh
    ../../../test-support/shell/assert-not-equals.sh
    ../../../test-support/shell/test-assert-not-equals.sh
    ../../../test-support/shell/assert-files-equal.sh
    ../../../test-support/shell/test-assert-files-equal.sh
    ../../../test-support/shell/assert-between.sh
    ../../../test-support/shell/test-assert-between.sh
    ../../../test-support/shell/assert-missing.sh
    ../../../test-support/shell/test-assert-missing.sh
    ../../../test-support/shell/wait-for.sh
  ];
}
