# The shell test helper the checks read from scripts/src/test-utils/shell, as one store directory
# that holds that file and no other: wait-for.sh. Every other file in scripts/src/test-utils/shell
# stays out, so an edit to a stand-in the checks never read changes no check's derivation. The
# nixos gate of .github/gates.yml lists the same file as an input of the checks: a file added here
# is added there too.
{ lib }:
lib.fileset.toSource {
  root = ../../../scripts/src/test-utils/shell;
  fileset = ../../../scripts/src/test-utils/shell/wait-for.sh;
}
