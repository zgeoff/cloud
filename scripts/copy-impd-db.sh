#!/usr/bin/env bash
# Take a consistent copy of impd's database on geoffcloud while impd runs, for a rollback
# before an imp upgrade (#9). Run it from this machine:
#
#   bash scripts/copy-impd-db.sh <label>      # such as imp-0.29.0-pre-0.30.0
#
# impd keeps its database in WAL mode inside imp-host's own mount of tank/imp, so a tar of
# imp.sqlite* while impd runs can tear, and the host cannot reach the files: SQLite
# resolves /proc/<pid>/root back to the host's root. So a static sqlite3 runs inside
# imp-host and writes one `VACUUM INTO` file: a single read transaction, consistent while
# impd writes, with no -wal or -shm beside it. The copy holds token hashes and secret
# metadata, so it stays root-only on the host. Until imp's CLI ships `db copy` (imp #171).
# The host side is copy-impd-db-host, which the host's NixOS config puts on its PATH
# (nixos/packages/impd-db-tools), so a change to it reaches the host only with a host switch.
set -euo pipefail

label="${1:?usage: copy-impd-db.sh <label>, such as imp-0.29.0-pre-0.30.0}"
host="${IMPD_DB_HOST:-root@geoffcloud}"

if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "the label may hold only letters, digits, '.', '_' and '-'" >&2
  exit 1
fi

# tailscaled logs the command line in full; it holds only the label, which is no secret
ssh -o BatchMode=yes "$host" "copy-impd-db-host $label" < /dev/null
