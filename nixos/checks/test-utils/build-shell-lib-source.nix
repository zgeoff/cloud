# The shell test helpers the checks read from scripts/test-utils/shell, as one store directory that
# holds those files and no other: run-cases.sh, the assert_* helpers and wait-for.sh, with the
# suites of run-cases.sh and the assert_* helpers, which test-utils-check.nix runs. Every other
# file in scripts/test-utils/shell stays out, so an edit to a stand-in the checks never read changes no
# check's derivation. The nixos gate of .github/gates.yml lists the same files as inputs of the
# checks: a file added here is added there too.
{ lib }:
lib.fileset.toSource {
  root = ../../../scripts/test-utils/shell;
  fileset = lib.fileset.unions [
    ../../../scripts/test-utils/shell/run-cases.sh
    ../../../scripts/test-utils/shell/test-run-cases.sh
    ../../../scripts/test-utils/shell/assert-equals.sh
    ../../../scripts/test-utils/shell/test-assert-equals.sh
    ../../../scripts/test-utils/shell/assert-not-equals.sh
    ../../../scripts/test-utils/shell/test-assert-not-equals.sh
    ../../../scripts/test-utils/shell/assert-files-equal.sh
    ../../../scripts/test-utils/shell/test-assert-files-equal.sh
    ../../../scripts/test-utils/shell/assert-between.sh
    ../../../scripts/test-utils/shell/test-assert-between.sh
    ../../../scripts/test-utils/shell/assert-missing.sh
    ../../../scripts/test-utils/shell/test-assert-missing.sh
    ../../../scripts/test-utils/shell/wait-for.sh
  ];
}
