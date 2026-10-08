# A stand-in sqlite3 for the impd-restore rehearsal's reset check: the real sqlite3, except that
# it never answers the check of the staged copy, so a test can interrupt the script at that
# point. When an argument opens the staged file (file:<dir>/imp.sqlite.restore?...), it writes
# its PID to $HOLDER_PID_FILE and then becomes `sleep infinity` under that PID, so it answers
# nothing until it is killed. The PID file appears only once the script is inside the check, with
# the copy staged in the mount, which is the test's signal to interrupt it. Any other call is the
# real sqlite3 alone. Without $HOLDER_PID_FILE it exits 2.
#
#   SQLITE3=<this> HOLDER_PID_FILE=/tmp/holder.pid bash restore-impd-db.sh ...
#
# The PID file is the one the rehearsal's reset reads, so a stand-in left blocked after its
# script is killed is ended by the reset like any other holder. What it assumes of
# scripts/restore-impd-db.sh, which nixos/checks/test-utils-check.nix pins: it stages the copy
# as db/imp.sqlite.restore inside the mount and checks it through $SQLITE3 with a file: URI.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.writeShellScript "sqlite3-blocking-on-staged-check" ''
  set -euo pipefail
  if [ -z "''${HOLDER_PID_FILE:-}" ]; then
    echo "sqlite3-blocking-on-staged-check: set HOLDER_PID_FILE to the file that names the blocked process" >&2
    exit 2
  fi
  for arg in "$@"; do
    case "$arg" in
      file:*/imp.sqlite.restore\?*)
        # written whole, then renamed, so a reader never sees a partial PID
        echo "$$" > "$HOLDER_PID_FILE.partial"
        mv "$HOLDER_PID_FILE.partial" "$HOLDER_PID_FILE"
        exec ${pkgs.coreutils}/bin/sleep infinity < /dev/null
        ;;
    esac
  done
  exec ${pkgs.sqlite}/bin/sqlite3 "$@"
''
