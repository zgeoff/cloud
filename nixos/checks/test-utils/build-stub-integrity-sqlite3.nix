# A stand-in sqlite3 for the copy subtests of the impd-restore rehearsal: the real sqlite3,
# except that it answers `PRAGMA integrity_check;` on any file with one finding, as SQLite
# reports an index whose entries do not match its table. A real copy cannot fail the check:
# VACUUM INTO rebuilds every index from its table. Any other call is the real sqlite3 alone.
#
#   SQLITE3=<this> bash -s -- <label> < scripts/copy-impd-db-host.sh
#
# What it assumes, which nixos/checks/test-utils-check.nix pins: the finding's text is
# SQLite's own, and scripts/copy-impd-db-host.sh runs integrity_check through SQLITE3 as a
# database path and that one statement.
{ pkgs }:
pkgs.writeShellScript "sqlite3-failing-integrity-check" ''
  set -euo pipefail
  if [ "$#" = 2 ] && [ "$2" = "PRAGMA integrity_check;" ]; then
    echo "wrong # of entries in index sqlite_autoindex_imps_1"
    exit 0
  fi
  exec ${pkgs.sqlite}/bin/sqlite3 "$@"
''
