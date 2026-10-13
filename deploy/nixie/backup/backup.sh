#!/bin/sh
# nixie-backup backup|restore|ls, run in the atc-gateway-backup image (restic and sqlite3)
#
# backup:  copy nixie.db, then keys.db, from $STATE_DIR with sqlite3 .backup (consistent while
#          nixie writes), copy both again if nixie removed a record key in between, check each
#          copy with PRAGMA integrity_check, upload both with restic, then apply retention.
# restore: restore the latest snapshot (or $SNAPSHOT) into a scratch directory, check both
#          databases, stage both on $STATE_DIR, and only then replace them, with their -wal and
#          -shm files.
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
    # nixie creates a record key before the record that uses it, and commits an item's forget
    # before it removes the key. So nixie.db is copied first, and a key removed between the two
    # copies leaves a pair that holds the item without its forget: the copy runs again then.
    before=/tmp/nixie-backup-keys-before.db
    attempt=1
    while :; do
      rm -rf "$work" "$before"
      mkdir -m 0700 "$work"
      sqlite3 "$state_dir/keys.db" ".backup '$before'"
      for name in $databases; do
        sqlite3 "$state_dir/$name" ".backup '$work/$name'"
        sqlite3 "$work/$name" 'PRAGMA integrity_check;' | grep -qx ok ||
          { echo "the copy of $name failed the integrity check" >&2; exit 1; }
      done
      removed=$(sqlite3 "$work/keys.db" "ATTACH '$before' AS before;
        SELECT count(*) FROM before.record_keys
        WHERE key_id NOT IN (SELECT key_id FROM main.record_keys);")
      rm -f "$before"
      [ "$removed" = 0 ] && break
      [ "$attempt" -lt 5 ] ||
        { echo "nixie removed record keys during each of $attempt copies" >&2; exit 1; }
      echo "nixie removed $removed record keys during the copy; copying again"
      attempt=$((attempt + 1))
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
    # stage both copies on the state volume first, so a full volume or an I/O error stops the
    # restore before it deletes anything, and each database then replaces its old one by rename
    for name in $databases; do
      cp "$work/$name" "$state_dir/$name.restoring" ||
        { rm -f "$state_dir"/*.restoring; echo "cannot stage $name in $state_dir" >&2; exit 1; }
    done
    for name in $databases; do
      rm -f "$state_dir/$name-wal" "$state_dir/$name-shm"
      mv "$state_dir/$name.restoring" "$state_dir/$name"
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
