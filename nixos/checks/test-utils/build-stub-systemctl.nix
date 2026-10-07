# A stand-in systemctl for the impd-restore rehearsal: the real systemctl, except that it cannot
# read one unit's state. The call `show -p ActiveState --value <unit>`, for the unit
# $FAIL_SHOW_UNIT names, prints systemctl's own failure line for a property read it cannot make
# and exits 1, as systemctl does when it cannot reach the manager. Every other call, with any
# other arguments, is the real systemctl with the same arguments: the script under test also
# reads the other unit's state, and its failure path stops the units, so the stand-in passes
# what it does not expect through rather than failing it. Without $FAIL_SHOW_UNIT it exits 2.
#
#   SYSTEMCTL=<this> FAIL_SHOW_UNIT=imp-docker-proxy bash restore-impd-db.sh ...
#
# What it assumes of scripts/restore-impd-db.sh, which nixos/checks/test-utils-check.nix pins:
# it reads each unit's state through $SYSTEMCTL as `show -p ActiveState --value <unit>`.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.writeShellScript "systemctl-failing-one-state-read" ''
  set -euo pipefail
  if [ -z "''${FAIL_SHOW_UNIT:-}" ]; then
    echo "systemctl-failing-one-state-read: set FAIL_SHOW_UNIT to the unit whose state read fails" >&2
    exit 2
  fi
  if [ "$#" -eq 5 ] && [ "$1" = show ] && [ "$2" = -p ] && [ "$3" = ActiveState ] &&
    [ "$4" = --value ] && [ "$5" = "$FAIL_SHOW_UNIT" ]; then
    # systemctl show's own message for a property read that fails
    echo "Failed to get properties: Connection timed out" >&2
    exit 1
  fi
  exec ${pkgs.systemd}/bin/systemctl "$@"
''
