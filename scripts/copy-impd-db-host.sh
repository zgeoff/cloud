#!/usr/bin/env bash
# The host side of copy-impd-db.sh: copy-impd-db.sh sends this file on ssh's stdin and runs it
# on geoffcloud as `bash -s -- <label>`, so $1 is the label, which copy-impd-db.sh has checked.
# A static sqlite3 runs inside imp-host and writes one `VACUUM INTO` file, a consistent copy
# while impd writes; the host's own sqlite3 then checks it and reads its newest migration.
# Every file it makes is root-only: the host shell and each `docker exec` shell set umask 077,
# and the container side works in its own mktemp directory (mode 0700), so two runs never share
# or remove each other's files. nixos/checks/impd-restore.nix runs it in the restore VM.
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
# SQLITE3 is for the restore VM, which checks a failed integrity_check; ssh never sends it
sqlite=${SQLITE3:-$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3}
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
# integrity_check prints one finding per line; COPY-INFO keeps them on its one integrity line
integrity=${integrity//$'\n'/; }
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
