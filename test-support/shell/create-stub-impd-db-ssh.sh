# shellcheck shell=bash
# create_stub_impd_db_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the host that
# copy-impd-db.sh copies impd's database on. It never runs the host's copy-impd-db-host
# (nixos/packages/impd-db-tools): the copy needs root, Docker and the imp-host container, which
# no case has (nixos/checks/impd-restore.nix runs it in the restore VM). It logs each call's
# argv as a JSON line to STUB_TREE/calls, writes what it reads on stdin to STUB_TREE/stdin, and
# answers one `copy-impd-db-host <label>` command, whose label is letters, digits, '.', '_' and
# '-', as the host does:
#
# - by default, a copy made at 2026-10-08T12:00:00Z: the COPY-INFO lines (path, sizeBytes,
#   lastMigration, impVersion, createdAt, integrity ok, image) and the "copy: <dir> (<size>
#   bytes, mode 600)" line, exit 0;
# - with STUB_COPY_FAIL=integrity, the same report with integrity set to the findings of a
#   damaged index, joined with "; " as the script joins them, exit 1 from its last `test`;
# - with STUB_COPY_FAIL=imp-host-stopped, docker's "No such container: imp-host" error on
#   stderr when the script makes its work directory, exit 1: imp's module runs imp-host with
#   --rm, so a stopped imp-host leaves no container. nixos/checks/impd-restore.nix gets this
#   answer from the real docker for the real script.
#
# The findings are the real sqlite3's report on the damaged database of
# nixos/checks/test-utils/build-stub-integrity-sqlite3.nix: an empty page in place of the index
# sqlite_autoindex_imps_1 of a three-row table. nixos/checks/impd-restore.nix runs the real
# script on that report and checks the same joined line.
#
# With STUB_SSH_PASS=1, a call after it is logged goes through print-ssh-pass-through.sh's
# guard: to the real ssh for a loopback destination, else exit 97. A call without
# `-o BatchMode=yes`, to a host other than STUB_HOST, or with any other remote command ends
# with exit 97 and "unexpected: <argv>" on stderr.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/print-ssh-pass-through.sh"

create_stub_impd_db_ssh() {
  local bin="$1"
  {
    echo '#!/usr/bin/env bash'
    cat << 'STUB'
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
STUB
    print_ssh_pass_through
    cat << 'STUB'
if [ "$#" != 4 ] || [ "$3" != "$STUB_HOST" ] || [[ ! "$4" =~ ^copy-impd-db-host\ ([A-Za-z0-9._-]+)$ ]]; then
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
if [ "${STUB_COPY_FAIL:-}" = integrity ]; then integrity="wrong # of entries in index sqlite_autoindex_imps_1; row 1 missing from index sqlite_autoindex_imps_1; row 2 missing from index sqlite_autoindex_imps_1; row 3 missing from index sqlite_autoindex_imps_1"; fi
printf 'path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n' \
  "$dir/imp.sqlite" 73728 0002_tokens 0.29.0 2026-10-08T12:00:00Z "$integrity" ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
echo "copy: $dir (73728 bytes, mode 600)"
[ "$integrity" = ok ]
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
