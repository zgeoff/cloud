# shellcheck shell=bash
# create_stub_impd_db_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the host that
# copy-impd-db.sh copies impd's database on. It never runs the script it is sent: the copy
# needs root, Nix and the imp-host container, which no case has (nixos/checks/impd-restore.nix
# runs it in the restore VM). It logs each call's argv as a JSON line to STUB_TREE/calls,
# writes the script it reads on stdin to STUB_TREE/stdin, and answers one
# `bash -s -- <label>` command, whose label is letters, digits, '.', '_' and '-', as the
# host does:
#
# - by default, a copy made at 2026-10-08T12:00:00Z: the COPY-INFO lines (path, sizeBytes,
#   lastMigration, impVersion, createdAt, integrity ok, image) and the "copy: <dir> (<size>
#   bytes, mode 600)" line, exit 0;
# - with STUB_COPY_FAIL=integrity, the same report with integrity set to SQLite's
#   integrity_check finding, exit 1 from the script's last `test`;
# - with STUB_COPY_FAIL=imp-host-stopped, docker's "No such container: imp-host" error on
#   stderr when the script makes its work directory, exit 1: imp's module runs imp-host with
#   --rm, so a stopped imp-host leaves no container. nixos/checks/impd-restore.nix gets this
#   answer from the real docker for the real script.
#
# The integrity finding was checked on 2026-10-08 against SQLite's source and a real
# sqlite3. src/pragma.c at version-3.51.2, the sqlite of nixpkgs
# 4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1 (nixos/flake.lock) that the script runs,
# reports "wrong # of entries in index <index>" (line 1794). sqlite3 3.53.4 printed that
# line for a table whose unique index was pointed at another table's index b-tree, among
# three other lines ("2nd reference to page 5", "Page 3: never used", "row 2 missing from
# index sqlite_autoindex_imps_1"). Left open: a real integrity_check prints every finding,
# one per line, and which ones depends on the damage, so the stand-in's one line stands for
# the shortest failing report.
#
# With STUB_SSH_PASS=1, a call to a loopback destination (ssh://<user>@127.0.0.1:<port>)
# goes to the real ssh after it is logged, with -F /dev/null so no ssh config on the
# machine applies, so a case reaches a real refused connection. An argument after the
# destination that starts with `-`, which OpenSSH would still read as an option, ends the
# call with exit 97 before the real ssh runs. The real ssh is the one on the fixed system
# path (/usr/local/bin, /usr/bin, /bin) when the stand-in is created, never one from the
# caller's PATH. A call without `-o BatchMode=yes`, to a host other than STUB_HOST, with
# any other remote command, or with STUB_SSH_PASS=1 to any destination but loopback ends
# with exit 97 and "unexpected: <argv>" on stderr.
create_stub_impd_db_ssh() {
  local bin="$1" real_ssh
  real_ssh="$(PATH=/usr/local/bin:/usr/bin:/bin command -v ssh || true)"
  {
    printf '#!/usr/bin/env bash\nreal_ssh=%q\n' "$real_ssh"
    cat << 'STUB'
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ -n "${STUB_SSH_PASS:-}" ]; then
  for arg in "${@:4}"; do
    if [[ "$arg" == -* ]]; then echo "unexpected: $*" >&2; exit 97; fi
  done
  if [ -n "$real_ssh" ] && [[ "$3" =~ ^ssh://[a-z]+@127\.0\.0\.1:[0-9]+$ ]]; then exec "$real_ssh" -F /dev/null "$@"; fi
  echo "unexpected: $*" >&2
  exit 97
fi
if [ "$#" != 4 ] || [ "$3" != "$STUB_HOST" ] || [[ ! "$4" =~ ^bash\ -s\ --\ ([A-Za-z0-9._-]+)$ ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
cat > "$STUB_TREE/stdin"
dir="/root/imp-db-backups/${BASH_REMATCH[1]}-20261008T120000"
if [ "${STUB_COPY_FAIL:-}" = imp-host-stopped ]; then
  echo "Error response from daemon: No such container: imp-host" >&2
  exit 1
fi
integrity=ok
if [ "${STUB_COPY_FAIL:-}" = integrity ]; then integrity="wrong # of entries in index sqlite_autoindex_imps_1"; fi
printf 'path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n' \
  "$dir/imp.sqlite" 73728 0002_tokens 0.29.0 2026-10-08T12:00:00Z "$integrity" ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
echo "copy: $dir (73728 bytes, mode 600)"
[ "$integrity" = ok ]
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
