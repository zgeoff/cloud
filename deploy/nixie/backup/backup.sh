#!/bin/sh
# nixie-backup backup|restore|ls, run in the atc-gateway-backup image (restic)
#
# backup:  upload the copy that `nixie backup` left in /tmp/nixie-backup, in the backup pod's init
#          container, then apply retention.
# restore: restore the latest snapshot (or $SNAPSHOT) into an empty /tmp/nixie-backup, where the
#          restore pod's `nixie restore` reads it.
# ls:      list snapshots.
#
# nixie's own commands read and replace its databases (nixie's
# docs/architecture/deployment/host-commands.md), so this script never opens a file of nixie's: it
# moves the directory those commands write and read, whatever it holds.
#
# Environment: RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE), and the repository's
# credentials (AWS_* for R2). Nothing here prints them.
set -eu

tag=nixie
host=nixie

# Every backup reads from this one path, so restic's retention groups every nixie snapshot
# together. forget also groups by host and tags only, and filters by both.
copy_dir=/tmp/nixie-backup

case "${1:-}" in
  backup)
    [ -n "$(ls -A "$copy_dir" 2> /dev/null)" ] || {
      echo "no copy from nixie backup in $copy_dir" >&2
      exit 1
    }
    restic cat config > /dev/null 2>&1 || restic init
    (cd "$copy_dir" && restic backup --tag "$tag" --host "$host" .)
    restic forget --tag "$tag" --host "$host" --group-by host,tags \
      --keep-daily 7 --keep-weekly 4 --prune
    ;;
  restore)
    [ -d "$copy_dir" ] || mkdir -m 0700 "$copy_dir"
    [ -z "$(ls -A "$copy_dir")" ] || {
      echo "$copy_dir is not empty" >&2
      exit 1
    }
    restic restore "${SNAPSHOT:-latest}" --tag "$tag" --host "$host" --target "$copy_dir"
    ;;
  ls)
    restic snapshots --tag "$tag" --host "$host"
    ;;
  *)
    echo "usage: nixie-backup backup|restore|ls" >&2
    exit 2
    ;;
esac
