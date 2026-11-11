#!/usr/bin/env bash
# Test for pepys's bucket backup script (backup.sh), with a stand-in rclone that records each
# call. It needs no Docker, no Garage and no R2: it proves the calls the script makes, not that
# rclone copies.
#
#   bash deploy/pepys/backup/test-backup.sh
#   CASE='stops' bash deploy/pepys/backup/test-backup.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup.sh"

setup_test() {
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  cat > "$tree/bin/rclone" << 'STUB'
#!/bin/sh
echo "rclone $*" >> "$RCLONE_LOG"
case "$2" in garage:broken) exit 7 ;; esac
STUB
  chmod +x "$tree/bin/rclone"
}

run_backup_script() {
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    RCLONE_LOG="$tree/rclone.log" "$@"
}

it_copies_each_named_bucket_to_its_own_folder_of_the_target_by_checksum() {
  create_case_tree
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" facts blobs > "$tree/out"

  diff - "$tree/rclone.log" << 'EOF2'
rclone copy garage:facts r2:pepys-backup/facts --checksum
rclone copy garage:blobs r2:pepys-backup/blobs --checksum
EOF2
  diff - "$tree/out" << 'EOF2'
copied facts
copied blobs
EOF2
}

it_stops_at_the_first_bucket_that_fails_and_copies_no_later_one() {
  local status=0
  create_case_tree
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" broken facts > /dev/null || status=$?

  assert_status 7 "$status"
  diff - "$tree/rclone.log" <<< 'rclone copy garage:broken r2:pepys-backup/broken --checksum'
}

it_refuses_to_run_without_a_target_bucket() {
  local status=0
  create_case_tree
  setup_test

  run_backup_script sh "$script" facts 2> "$tree/err" || status=$?

  # the exit status of a failed ${name:?} expansion differs between shells
  [ "$status" != 0 ]
  grep -q 'set PEPYS_BACKUP_BUCKET' "$tree/err"
  [ ! -e "$tree/rclone.log" ]
}

it_refuses_to_run_without_a_bucket_to_copy() {
  local status=0
  create_case_tree
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" 2> "$tree/err" || status=$?

  assert_status 2 "$status"
  diff - "$tree/err" <<< 'usage: backup.sh <bucket>...'
  [ ! -e "$tree/rclone.log" ]
}

run_cases
