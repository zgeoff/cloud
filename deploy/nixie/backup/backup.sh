#!/bin/sh
# nixie-backup backup|restore|ls, run in the atc-gateway-backup image (restic and sqlite3)
#
# backup:  copy nixie.db and keys.db from $STATE_DIR with sqlite3 .backup (consistent while
#          nixie writes), check each copy with PRAGMA integrity_check, upload both with restic,
#          then apply retention.
# restore: restore the latest snapshot (or $SNAPSHOT) into a scratch directory, check both
#          databases, and only then replace them in $STATE_DIR, with their -wal and -shm files.
#          Run it only while nixie is stopped.
# ls:      list snapshots.
#
# Only nixie.db and keys.db are copied: keys.db holds the record keys, wrapped by the deployment
# key, and nixie.db holds the records they encrypt, so one is useless without the other. Other
# files on the volume, such as nixie's pre-migration copies (nixie-schema-<n>.db) and its control
# socket, stay out.
#
# Environment: STATE_DIR, RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE), and the
# repository's credentials (AWS_* for R2). Nothing here prints them.
set -eu

state_dir="${STATE_DIR:?set STATE_DIR}"
tag=nixie
host=nixie
databases='nixie.db keys.db'

# Every backup reads from this one path, so restic's retention groups every nixie snapshot
# together. forget also groups by host and tags only, and filters by both.
source_dir=/tmp/nixie-backup

case "${1:-}" in
  backup)
    # sqlite3 creates a database it cannot find, so check for each before any copy
    for name in $databases; do
      [ -e "$state_dir/$name" ] || { echo "no $name in $state_dir" >&2; exit 1; }
    done
    restic cat config > /dev/null 2>&1 || restic init
    work="$source_dir"
    rm -rf "$work"
    mkdir -m 0700 "$work"
    for name in $databases; do
      sqlite3 "$state_dir/$name" ".backup '$work/$name'"
      sqlite3 "$work/$name" 'PRAGMA integrity_check;' | grep -qx ok ||
        { echo "the copy of $name failed the integrity check" >&2; exit 1; }
    done
    (cd "$work" && restic backup --tag "$tag" --host "$host" .)
    restic forget --tag "$tag" --host "$host" --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --prune
    rm -rf "$work"
    ;;
  restore)
    work=$(mktemp -d)
    restic restore "${SNAPSHOT:-latest}" --tag "$tag" --host "$host" --target "$work"
    for name in $databases; do
      [ -e "$work/$name" ] || { echo "the snapshot holds no $name" >&2; exit 1; }
      sqlite3 "$work/$name" 'PRAGMA integrity_check;' | grep -qx ok ||
        { echo "the restored $name failed the integrity check" >&2; exit 1; }
    done
    for name in $databases; do
      rm -f "$state_dir/$name" "$state_dir/$name-wal" "$state_dir/$name-shm"
      cp "$work/$name" "$state_dir/$name"
      echo "restored $name: integrity_check ok"
    done
    rm -rf "$work"
    ;;
  ls)
    restic snapshots --tag "$tag" --host "$host"
    ;;
  *)
    echo "usage: nixie-backup backup|restore|ls" >&2
    exit 2
    ;;
esac
