# shellcheck shell=bash
# The host side of scripts/copy-impd-db.sh, packaged as copy-impd-db-host on geoffcloud's PATH
# (default.nix beside it): copy-impd-db.sh runs `copy-impd-db-host <label>` over ssh.
# A static sqlite3 runs inside imp-host and writes one `VACUUM INTO` file, a consistent copy
# while impd writes; the host's sqlite3 then checks it and reads its newest migration. Both
# sqlite3s come from the flake's pinned nixpkgs: the package puts one on PATH and names the
# static one in STATIC_SQLITE3. SQLITE3 names the checking sqlite3 instead, for the restore VM,
# which checks a failed integrity_check. Every file it makes is root-only: the host shell and
# each `podman exec` shell set umask 077, and the container side works in its own mktemp
# directory (mode 0700), so two runs never share or remove each other's files.
# nixos/checks/impd-restore.nix runs it in the restore VM.
umask 077
label="${1:?usage: copy-impd-db-host <label>, such as imp-0.29.0-pre-0.30.0}"
# the label starts the copy's directory name, so a '/' would put the copy elsewhere; the same
# check as copy-impd-db.sh's, for a run on the host without it
if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "the label may hold only letters, digits, '.', '_' and '-'" >&2
  exit 1
fi
static="$STATIC_SQLITE3"
sqlite="${SQLITE3:-sqlite3}"
# on geoffcloud the directory is a bind mount of tank/cloud/imp-db-backups; with the mount gone
# (a failed key or mount), a copy would land in the clear on the root disk, and the bind would
# hide it later. The restore rehearsal VMs have no mount and set the variable.
if [ -z "${COPY_IMPD_DB_ALLOW_UNMOUNTED:-}" ] && ! mountpoint -q /root/imp-db-backups; then
  echo "/root/imp-db-backups is not a mount point; nothing copied" >&2
  exit 1
fi
# /root exists, so -m sets the mode of the one directory this creates
# shellcheck disable=SC2174
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$label-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(podman exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *)
  echo "unexpected work dir: $work" >&2
  exit 1
  ;;
esac
# $work is checked above, so the trap holds its value now
# shellcheck disable=SC2064
trap "podman exec imp-host rm -rf -- \"$work\"" EXIT
podman cp "$static" "imp-host:$work/sqlite3"
podman exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
podman cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
# integrity_check prints one finding per line; COPY-INFO keeps them on its one integrity line
integrity=${integrity//$'\n'/; }
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
# impz is imp's CLI from its rename on; an imp-host image from before the rename has only imp
version=$(podman exec imp-host sh -c 'if command -v impz > /dev/null; then impz info; else imp info; fi' |
  sed -n "s/^version *//p")
# Podman names an image pulled by tag and digest by its digest alone, as <name>@sha256:<digest>;
# restore-impd-db compares the name and digest only
image=$(podman inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `impz db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
