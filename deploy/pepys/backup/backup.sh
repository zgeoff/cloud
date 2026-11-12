#!/bin/sh
# pepys-backup <bucket>...: copy each named Garage bucket to $PEPYS_BACKUP_BUCKET/<bucket> in R2,
# run in the rclone image by the pepys-backup CronJob. `rclone copy` never deletes an object at
# the target, so a bucket emptied by mistake leaves the copies in R2. --checksum compares by hash,
# so an object rewritten with the same size and time still copies.
#
# Environment: PEPYS_BACKUP_BUCKET, and the remotes `garage` and `r2` as RCLONE_CONFIG_GARAGE_* and
# RCLONE_CONFIG_R2_*. Nothing here prints them.
set -eu

target="${PEPYS_BACKUP_BUCKET:?set PEPYS_BACKUP_BUCKET}"

if [ "$#" = 0 ]; then
  echo "usage: backup.sh <bucket>..." >&2
  exit 2
fi

for bucket in "$@"; do
  rclone copy "garage:$bucket" "r2:$target/$bucket" --checksum
  echo "copied $bucket"
done
