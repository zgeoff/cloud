#!/bin/sh
# atc-gateway-backup backup|restore|ls
#
# backup:  copy every *.db in $STATE_DIR with sqlite3 .backup (consistent while the
#          gateway writes), upload the copies with restic, then apply retention.
# restore: restore the latest snapshot (or $SNAPSHOT) into $STATE_DIR. Run it only
#          while the gateway is stopped: it replaces the files.
# ls:      list snapshots.
#
# Environment: STATE_DIR, RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE),
# and the repository's credentials (AWS_* for R2). Nothing here prints them.
set -eu

state_dir="${STATE_DIR:?set STATE_DIR}"
tag=atc-gateway
host=atc-gateway

# Every backup reads from this one path. restic's forget groups snapshots by host and
# path by default, so a new mktemp path per run made every snapshot its own group, and
# none ever aged out. forget below also groups by host and tags only, and filters by
# both, so it never touches another tool's snapshots in a shared repository.
source_dir=/tmp/atc-gateway-backup

case "${1:-}" in
  backup)
    restic cat config > /dev/null 2>&1 || restic init
    work="$source_dir"
    rm -rf "$work"
    mkdir -m 0700 "$work"
    found=0
    for db in "$state_dir"/*.db; do
      [ -e "$db" ] || continue
      sqlite3 "$db" ".backup '$work/$(basename "$db")'"
      sqlite3 "$work/$(basename "$db")" 'PRAGMA integrity_check;' | grep -qx ok
      found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { echo "no databases in $state_dir" >&2; exit 1; }
    (cd "$work" && restic backup --tag "$tag" --host "$host" .)
    restic forget --tag "$tag" --host "$host" --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --prune
    rm -rf "$work"
    ;;
  restore)
    work=$(mktemp -d)
    restic restore "${SNAPSHOT:-latest}" --tag "$tag" --host "$host" --target "$work"
    for db in "$work"/*.db; do
      [ -e "$db" ] || { echo "snapshot holds no databases" >&2; exit 1; }
      sqlite3 "$db" 'PRAGMA integrity_check;' | grep -qx ok
    done
    for db in "$work"/*.db; do
      name=$(basename "$db")
      rm -f "$state_dir/$name" "$state_dir/$name-wal" "$state_dir/$name-shm"
      cp "$db" "$state_dir/$name"
    done
    rm -rf "$work"
    ;;
  ls)
    restic snapshots --tag "$tag" --host "$host"
    ;;
  *)
    echo "usage: atc-gateway-backup backup|restore|ls" >&2
    exit 2
    ;;
esac
