# A stand-in sqlite3 for the copy subtests of the impd-restore rehearsal: the real sqlite3,
# except that it answers `PRAGMA integrity_check;` on any file with the real sqlite3's report on
# a damaged database: one whose unique index sqlite_autoindex_imps_1 holds an empty index page,
# made at build time by copying another table's empty index page over it. A real copy cannot
# fail the check: VACUUM INTO rebuilds every index from its table. Any other call is the real
# sqlite3 alone.
#
#   SQLITE3=<this> bash -s -- <label> < scripts/copy-impd-db-host.sh
#
# What it assumes of scripts/copy-impd-db-host.sh, which nixos/checks/test-utils-check.nix
# pins: it runs integrity_check through SQLITE3 as a database path and that one statement.
{ pkgs }:
let
  damaged = pkgs.runCommand "damaged-imp.sqlite" { nativeBuildInputs = [ pkgs.sqlite ]; } ''
    sqlite3 db "CREATE TABLE imps (name TEXT UNIQUE); INSERT INTO imps VALUES ('a'),('b'),('c'); CREATE TABLE spare (name TEXT UNIQUE);"
    size=$(sqlite3 db 'PRAGMA page_size;')
    imps=$(sqlite3 db "SELECT rootpage FROM sqlite_schema WHERE name = 'sqlite_autoindex_imps_1';")
    spare=$(sqlite3 db "SELECT rootpage FROM sqlite_schema WHERE name = 'sqlite_autoindex_spare_1';")
    dd if=db of=db bs="$size" skip=$((spare - 1)) seek=$((imps - 1)) count=1 conv=notrunc status=none
    mv db $out
  '';
in
pkgs.writeShellScript "sqlite3-failing-integrity-check" ''
  set -euo pipefail
  if [ "$#" = 2 ] && [ "$2" = "PRAGMA integrity_check;" ]; then
    exec ${pkgs.sqlite}/bin/sqlite3 -readonly ${damaged} 'PRAGMA integrity_check;'
  fi
  exec ${pkgs.sqlite}/bin/sqlite3 "$@"
''
