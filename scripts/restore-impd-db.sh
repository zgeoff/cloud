#!/usr/bin/env bash
# Put a copy of impd's database back on geoffcloud (#9). Runs ON THE HOST, as root, after
# imp-host and imp-docker-proxy are masked and stopped, and after the host runs the NixOS
# generation whose imp image matches the copy (docs/runbooks/restore-geoff-cloud.md, section 2):
#
#   restore-impd-db.sh /root/imp-db-backups/<copy>
#
# It fails closed: every check runs before anything changes, and on any error it leaves both
# services masked and stopped, so impd never starts against a half-restored database. It
# changes nothing it has not first preserved: the stopped database and its WAL files go to
# /root/imp-db-backups/pre-restore-<UTC time>/. It stages the copy beside the database,
# checks it there, and publishes it with one rename. It unmasks and starts imp-host only
# after a clean unmount. A copy needs COPY-INFO from scripts/copy-impd-db.sh.
set -euo pipefail

copy="${1:?usage: restore-impd-db.sh /root/imp-db-backups/<copy>}"
dataset="${IMPD_DATASET:-tank/imp}"
backups="${IMPD_BACKUPS:-/root/imp-db-backups}"
sqlite="${SQLITE3:-sqlite3}"
units=(imp-host imp-docker-proxy)

fail() {
  echo "restore-impd-db: $*; nothing was started, and both services stay masked" >&2
  exit 1
}

trap 'echo "restore-impd-db: failed at line $LINENO; nothing was started, and both services stay masked" >&2' ERR

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
  [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = masked-runtime ] ||
    fail "$unit is not runtime-masked; run: systemctl mask --runtime ${units[*]}"
  if systemctl is-active --quiet "$unit"; then
    fail "$unit is running; run: systemctl stop ${units[*]}"
  fi
done
unit_image="$(grep -o 'ghcr.io/zgeoff/imp-host:[^ ;]*' /etc/systemd/system/imp-host.service | head -1)"
[ "$unit_image" = "$copy_image" ] ||
  fail "this generation runs $unit_image, but the copy is from $copy_image; switch generations first"
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

step "unmount"
trap - EXIT
umount "$mnt" || fail "cannot unmount $mnt"
mounted=false
rmdir "$mnt"

step "start"
systemctl unmask --runtime "${units[@]}"
systemctl start imp-host
echo "restored $copy (migration $copy_migration); the replaced database is in $saved"
