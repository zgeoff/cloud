# A stand-in sqlite3 for the impd-restore rehearsal: the real sqlite3, which also keeps the
# restore's mount busy from the moment the script checks its staged copy. When an argument opens
# the staged file (file:<dir>/imp.sqlite.restore?...), it first starts a process that sleeps with
# <dir> as its working directory, and writes that process's PID to $HOLDER_PID_FILE; it then
# runs the real sqlite3 with the same arguments. The holder forks from <dir>, so the mount is
# busy by the time sqlite3 runs. Any other call is the real sqlite3 alone.
#
#   SQLITE3=<this> HOLDER_PID_FILE=/tmp/holder.pid bash restore-impd-db.sh ...
#
# What it assumes of scripts/restore-impd-db.sh, which nixos/checks/test-utils-check.nix pins:
# it stages the copy as db/imp.sqlite.restore inside the mount and checks it through $SQLITE3
# with a file: URI. nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.writeShellScript "sqlite3-holding-staged-dir" ''
  set -euo pipefail
  for arg in "$@"; do
    case "$arg" in
      file:*/imp.sqlite.restore\?*)
        staged="''${arg#file:}"
        staged="''${staged%%\?*}"
        # the holder forks from this directory, so it is busy before the fork returns
        here="$PWD"
        cd "''${staged%/*}"
        ${pkgs.coreutils}/bin/sleep infinity < /dev/null > /dev/null 2>&1 &
        echo "$!" > "$HOLDER_PID_FILE"
        cd "$here"
        ;;
    esac
  done
  exec ${pkgs.sqlite}/bin/sqlite3 "$@"
''
