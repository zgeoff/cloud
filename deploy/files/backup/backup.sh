#!/bin/sh
# files-backup backup|restore|ls, run in the atc-gateway-backup image (restic and sqlite3)
#
# backup:  copy files.db from $STATE_DIR with sqlite3 .backup (consistent while the service writes)
#          to files-backup.db beside it, check the copy with PRAGMA integrity_check, then upload
#          the copy and the files/ directory with restic, and apply retention.
# restore: restore the copy of files.db from the latest snapshot (or $SNAPSHOT) into a scratch
#          directory and check it, then restore files/ onto $STATE_DIR, replace files.db and its
#          -wal and -shm files with the copy, and remove each file under files/ that the restored
#          metadata does not list. Run it only while the service is stopped.
# ls:      list snapshots.
#
# The metadata copy comes first, so a file the service writes after it lands in the snapshot with
# no row, and the restore removes it; a file the sweep removes after it is missing from the
# snapshot while its row has expired, and the next sweep removes the row. incoming/ holds only
# files being written, so it stays out.
#
# Environment: STATE_DIR, RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE), and the
# repository's credentials (AWS_* for R2). Nothing here prints them.
set -eu

state_dir="${STATE_DIR:?set STATE_DIR}"
tag=files
host=files
copy=files-backup.db

case "${1:-}" in
  backup)
    # sqlite3 creates a database it cannot find, so check for it before the copy
    [ -e "$state_dir/files.db" ] || {
      echo "no files.db in $state_dir" >&2
      exit 1
    }
    restic cat config > /dev/null 2>&1 || restic init
    rm -f "$state_dir/$copy"
    sqlite3 -bail "$state_dir/files.db" ".backup '$state_dir/$copy'"
    sqlite3 "$state_dir/$copy" 'PRAGMA integrity_check;' | grep -qx ok ||
      {
        echo "the copy of files.db failed the integrity check" >&2
        exit 1
      }
    mkdir -p "$state_dir/files"
    (cd "$state_dir" && restic backup --tag "$tag" --host "$host" "$copy" files)
    restic forget --tag "$tag" --host "$host" --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --prune
    rm -f "$state_dir/$copy"
    ;;
  restore)
    work=$(mktemp -d)
    snapshot="${SNAPSHOT:-latest}"
    restic restore "$snapshot" --tag "$tag" --host "$host" --target "$work" --include "/$copy"
    [ -e "$work/$copy" ] || {
      echo "the snapshot holds no $copy" >&2
      exit 1
    }
    sqlite3 "$work/$copy" 'PRAGMA integrity_check;' | grep -qx ok ||
      {
        echo "the restored $copy failed the integrity check" >&2
        exit 1
      }
    # stage the metadata on the state volume first, so a full volume stops the restore before it
    # changes anything
    cp "$work/$copy" "$state_dir/files.db.restoring" ||
      {
        rm -f "$state_dir/files.db.restoring"
        echo "cannot stage files.db in $state_dir" >&2
        exit 1
      }
    restic restore "$snapshot" --tag "$tag" --host "$host" --target "$state_dir" --include /files
    rm -f "$state_dir/files.db-wal" "$state_dir/files.db-shm"
    mv "$state_dir/files.db.restoring" "$state_dir/files.db"
    sqlite3 "$state_dir/files.db" 'SELECT id FROM uploads;' > "$work/ids"
    removed=0
    for path in "$state_dir"/files/*; do
      [ -e "$path" ] || continue
      grep -qxF "$(basename "$path")" "$work/ids" || {
        rm -f "$path"
        removed=$((removed + 1))
      }
    done
    echo "restored files.db: integrity_check ok, $(wc -l < "$work/ids") uploads, $removed files without a row removed"
    rm -rf "$work"
    ;;
  ls)
    restic snapshots --tag "$tag" --host "$host"
    ;;
  *)
    echo "usage: files-backup backup|restore|ls" >&2
    exit 2
    ;;
esac
