#!/usr/bin/env bash
# Put a copy of impd's database back on geoffcloud (#9). Runs ON THE HOST, as root, after
# imp-host and imp-docker-proxy are stopped (docs/runbooks/restore-geoff-cloud.md, section 2):
#
#   restore-impd-db.sh /root/imp-db-backups/<copy> <generation>
#
# <generation> is the NixOS generation whose imp-host image matches the copy's COPY-INFO. The
# order pairs them safely: restore the database while impd is stopped, then activate that
# generation, then start imp-host and check it runs the copy's image. A runtime mask cannot
# hold impd down through a switch on NixOS (the units in /etc outrank /run), so nothing here
# relies on one. It fails closed: every check runs before anything changes, and on any error
# it starts nothing and switches nothing. It preserves the stopped database and its WAL files
# in /root/imp-db-backups/pre-restore-<UTC time>/, stages the copy beside the database,
# checks it there, publishes it with one rename, and moves on only after a clean unmount.
# A copy needs COPY-INFO from scripts/copy-impd-db.sh.
set -euo pipefail

copy="${1:?usage: restore-impd-db.sh /root/imp-db-backups/<copy> <generation>}"
generation="${2:?usage: restore-impd-db.sh /root/imp-db-backups/<copy> <generation>}"
profiles="${NIX_PROFILES_DIR:-/nix/var/nix/profiles}"
dataset="${IMPD_DATASET:-tank/imp}"
backups="${IMPD_BACKUPS:-/root/imp-db-backups}"
sqlite="${SQLITE3:-sqlite3}"
units=(imp-host imp-docker-proxy)

# what has happened so far, for the error message
state="nothing was changed"

fail() {
  echo "restore-impd-db: $*; $state" >&2
  exit 1
}

trap 'echo "restore-impd-db: failed at line $LINENO; $state" >&2' ERR

step() {
  printf '== %s\n' "$*"
}

step "check the copy"
[ -f "$copy/imp.sqlite" ] || fail "$copy/imp.sqlite is missing"
[ -f "$copy/COPY-INFO" ] || fail "$copy/COPY-INFO is missing; only a copy-impd-db.sh copy is restorable"
[ "$("$sqlite" "$copy/imp.sqlite" 'PRAGMA integrity_check;')" = ok ] || fail "the copy fails integrity_check"
copy_image="$(sed -n 's/^image //p' "$copy/COPY-INFO")"
copy_migration="$(sed -n 's/^migration //p' "$copy/COPY-INFO")"
[ -n "$copy_image" ] && [ -n "$copy_migration" ] || fail "COPY-INFO lacks the image or the migration"
[ "$("$sqlite" "$copy/imp.sqlite" 'SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;')" = "$copy_migration" ] ||
  fail "the copy's newest migration differs from COPY-INFO"

step "check the host"
for unit in "${units[@]}"; do
  if systemctl is-active --quiet "$unit"; then
    fail "$unit is running; run: systemctl stop ${units[*]}"
  fi
done
[[ "$generation" =~ ^[0-9]+$ ]] || fail "the generation must be a number, such as 14"
target="$profiles/system-$generation-link"
[ -x "$target/bin/switch-to-configuration" ] || fail "generation $generation does not exist"
target_image="$(grep -o 'ghcr.io/zgeoff/imp-host:[^ ;]*' "$target/etc/systemd/system/imp-host.service" | head -1)"
[ "$target_image" = "$copy_image" ] ||
  fail "generation $generation runs $target_image, but the copy is from $copy_image"
if findmnt -rn -S "$dataset" > /dev/null; then
  fail "$dataset is already mounted"
fi

step "mount $dataset"
mnt="$(mktemp -d /run/impd-restore.XXXXXX)"
mount -t zfs "$dataset" "$mnt"
mounted=true
cleanup() {
  if [ -n "${staged:-}" ] && [ -e "$staged" ]; then
    rm -f "$staged"
  fi
  if [ "${mounted:-false}" = true ]; then
    umount "$mnt" || echo "restore-impd-db: $dataset is still mounted at $mnt; unmount it by hand" >&2
  fi
  rmdir "$mnt" 2> /dev/null || true
}
trap cleanup EXIT
db="$mnt/db"
[ -f "$db/imp.sqlite" ] || fail "$db/imp.sqlite is missing; is $dataset impd's dataset?"

step "preserve the stopped database"
umask 077
saved="$backups/pre-restore-$(date -u +%Y%m%dT%H%M%S)"
install -d -m 0700 "$backups"
mkdir -m 0700 "$saved"
for file in imp.sqlite imp.sqlite-wal imp.sqlite-shm; do
  if [ -e "$db/$file" ]; then
    cp -p "$db/$file" "$saved/$file"
    cmp -s "$db/$file" "$saved/$file" || fail "the saved $file differs from the original"
  fi
done
echo "saved: $saved"
state="the original database is saved in $saved; nothing was started or switched"

step "stage and check the copy"
staged="$db/imp.sqlite.restore"
cp "$copy/imp.sqlite" "$staged"
chown --reference="$db/imp.sqlite" "$staged"
chmod --reference="$db/imp.sqlite" "$staged"
cmp -s "$copy/imp.sqlite" "$staged" || fail "the staged file differs from the copy"
[ "$("$sqlite" "file:$staged?mode=ro&immutable=1" 'PRAGMA integrity_check;')" = ok ] ||
  fail "the staged file fails integrity_check"
sync -f "$staged"

step "publish"
rm -f "$db/imp.sqlite-wal" "$db/imp.sqlite-shm"
mv -f "$staged" "$db/imp.sqlite"
sync -f "$db/imp.sqlite"
cmp -s "$copy/imp.sqlite" "$db/imp.sqlite" || fail "the published database differs from the copy"
state="the copy is in place (the original is in $saved); nothing was started or switched"

step "unmount"
trap - EXIT
umount "$mnt" || fail "cannot unmount $mnt"
mounted=false
rmdir "$mnt"

state="the copy is in place (the original is in $saved); the switch or start did not finish"
step "activate generation $generation"
if [ "$(readlink "$profiles/system")" != "system-$generation-link" ]; then
  nix-env -p "$profiles/system" --set "$target"
  "$target/bin/switch-to-configuration" switch
fi

step "start"
systemctl start imp-host
running_image="$(docker inspect imp-host --format '{{.Config.Image}}')"
[ "$running_image" = "$copy_image" ] ||
  fail "imp-host runs $running_image, not the copy's $copy_image; stop it and investigate"
echo "restored $copy (migration $copy_migration) on generation $generation; the replaced database is in $saved"
