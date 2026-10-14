# impd's database tools on geoffcloud's PATH: copy-impd-db-host takes a copy while impd runs
# (scripts/copy-impd-db.sh calls it over ssh), and restore-impd-db puts a copy back
# (docs/runbooks/restore-geoff-cloud.md). Each puts the sqlite3 of the flake's pinned nixpkgs
# first on PATH, so a copy is checked, and a restore checks it, with the same sqlite3 the host
# switch pinned. writeShellApplication runs shellcheck on each at build time. A fix to either
# reaches the host only with a host switch.
{
  lib,
  pkgsStatic,
  sqlite,
  symlinkJoin,
  writeShellApplication,
}:
let
  copy = writeShellApplication {
    name = "copy-impd-db-host";
    runtimeInputs = [ sqlite ];
    # the sqlite3 it copies into imp-host; static, so it runs there without the host's store
    runtimeEnv.STATIC_SQLITE3 = lib.getExe' pkgsStatic.sqlite.bin "sqlite3";
    text = builtins.readFile ./copy-impd-db-host.sh;
  };
  restore = writeShellApplication {
    name = "restore-impd-db";
    runtimeInputs = [ sqlite ];
    text = builtins.readFile ./restore-impd-db.sh;
  };
in
symlinkJoin {
  name = "impd-db-tools";
  paths = [
    copy
    restore
  ];
  passthru = { inherit copy restore; };
}
