# A stand-in cmp for the impd-restore rehearsal: the real cmp, except that one comparison finds
# a difference. The call `cmp -s <first> <second>`, where <first> is $FAIL_CMP_FIRST and <second>
# matches the bash glob $FAIL_CMP_SECOND, prints nothing and exits 1, as cmp -s does for two
# files that differ, whatever the files hold. Every other call, with any other arguments, is the
# real cmp with the same arguments: the script under test also compares each saved file with its
# original and the copy with the other target, so the stand-in passes what it does not expect
# through rather than failing it. Without both variables it exits 2.
#
#   CMP=<this> FAIL_CMP_FIRST=/root/imp-db-backups/<copy>/imp.sqlite \
#     FAIL_CMP_SECOND='/run/impd-restore.*/db/imp.sqlite.restore' bash restore-impd-db.sh ...
#
# What it assumes of scripts/restore-impd-db.sh, which nixos/checks/test-utils-check.nix pins:
# it compares through $CMP with -s, the copy first, then the staged file or the published
# database in db/ of a /run/impd-restore.XXXXXX mount, and each saved file second to its
# original. nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.writeShellScript "cmp-failing-one-comparison" ''
  set -euo pipefail
  if [ -z "''${FAIL_CMP_FIRST:-}" ] || [ -z "''${FAIL_CMP_SECOND:-}" ]; then
    echo "cmp-failing-one-comparison: set FAIL_CMP_FIRST and FAIL_CMP_SECOND to the comparison that fails" >&2
    exit 2
  fi
  # the glob is unquoted on purpose: FAIL_CMP_SECOND is a pattern
  # shellcheck disable=SC2053
  if [ "$#" -eq 3 ] && [ "$1" = -s ] && [ "$2" = "$FAIL_CMP_FIRST" ] && [[ "$3" == $FAIL_CMP_SECOND ]]; then
    exit 1
  fi
  exec ${pkgs.diffutils}/bin/cmp "$@"
''
