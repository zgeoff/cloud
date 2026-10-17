# A stand-in 1Password CLI for the checks that run scripts/install-imp-dns-token.sh in a VM. Given
# an attribute set from secret reference to value, it returns the package whose bin/op answers
# `op read --no-newline <reference>` with the value and no newline added, as the real op does.
# A reference outside the set prints op's "could not read secret" error and exits 1, and any other
# call fails with "unexpected: <argv>" and status 97.
#
#   PATH=${buildStubOpRead { "op://cloud/item/field" = "value"; }}/bin:$PATH
#
# What it assumes of op, which nixos/checks/test-utils-check.nix pins: install-imp-dns-token.sh
# reads each value with exactly `op read --no-newline <reference>`. The error line follows the
# text that 1Password users report for op 2, as test-support/shell/create-stub-op-read.sh does; no
# real op runs in a test.
{ pkgs }:
values:
pkgs.writeShellApplication {
  name = "op";
  text = ''
    if [ "$#" -ne 3 ] || [ "$1 $2" != "read --no-newline" ]; then
      echo "unexpected: $*" >&2
      exit 97
    fi
    case "$3" in
    ${pkgs.lib.concatStrings (
      pkgs.lib.mapAttrsToList (reference: value: ''
        ${pkgs.lib.escapeShellArg reference}) printf '%s' ${pkgs.lib.escapeShellArg value} ;;
      '') values
    )}
    *)
      echo "[ERROR] 2026/10/07 12:00:00 could not read secret $3" >&2
      exit 1
      ;;
    esac
  '';
}
