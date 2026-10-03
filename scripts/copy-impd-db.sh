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
# metadata, so it stays root-only on the host. Until imp ships `imp db copy` (imp #171).
set -euo pipefail

label="${1:?usage: copy-impd-db.sh <label>, such as imp-0.29.0-pre-0.30.0}"
host="${IMPD_DB_HOST:-root@geoffcloud}"

if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "the label may hold only letters, digits, '.', '_' and '-'" >&2
  exit 1
fi

# runs on the host; $1 is the label
# shellcheck disable=SC2016 # expanded on the host
remote='set -euo pipefail
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
trap "docker exec imp-host rm -f /tmp/impd-db-sqlite3 /tmp/impd-db-copy.sqlite" EXIT
docker cp "$static" imp-host:/tmp/impd-db-sqlite3
docker exec imp-host /tmp/impd-db-sqlite3 /var/lib/imp/db/imp.sqlite \
  "VACUUM INTO '"'"'/tmp/impd-db-copy.sqlite'"'"'"
umask 077
mkdir -p "$dir"
docker cp imp-host:/tmp/impd-db-copy.sqlite "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
printf "imp %s\nimage %s\nmigration %s\nintegrity %s\n" "$version" "$image" "$migration" "$integrity" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c %s "$dir/imp.sqlite") bytes)"
test "$integrity" = ok'

ssh -o BatchMode=yes "$host" "bash -c $(printf '%q' "$remote") _ $(printf '%q' "$label")"
