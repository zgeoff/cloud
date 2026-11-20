#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for pepys's bucket backup script (backup.sh), with a stand-in rclone that records each
# call. It needs no Docker, no Garage and no R2: it proves the calls the script makes, not that
# rclone copies.
#
#   bash scripts/run-bats.sh
#   CASE='stops' bash scripts/run-bats.sh

setup_file() {
  load '../../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../../scripts/src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  script="$BATS_TEST_DIRNAME/backup.sh"
}

teardown() {
  stop_timeout_watchdog
}

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

@test "it copies each named bucket to its own folder of the target by checksum" {
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" facts blobs > "$tree/out"

  diff - "$tree/rclone.log" << 'EOF'
rclone copy garage:facts r2:pepys-backup/facts --checksum
rclone copy garage:blobs r2:pepys-backup/blobs --checksum
EOF
  diff - "$tree/out" << 'EOF'
copied facts
copied blobs
EOF
}

@test "it stops at the first bucket that fails and copies no later one" {
  local status=0
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" broken facts > /dev/null || status=$?

  assert_equal "$status" 7

  diff - "$tree/rclone.log" <<< 'rclone copy garage:broken r2:pepys-backup/broken --checksum'
}

@test "it refuses to run without a target bucket" {
  local status=0
  setup_test

  # the exit status of a failed ${name:?} expansion differs between shells
  run_backup_script sh "$script" facts 2> "$tree/err" || status=$?

  refute [ "$status" = 0 ]
  grep -q 'set PEPYS_BACKUP_BUCKET' "$tree/err"
  refute [ -e "$tree/rclone.log" ]
  refute [ -L "$tree/rclone.log" ]
}

@test "it refuses to run without a bucket to copy" {
  local status=0
  setup_test

  run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff - "$tree/err" <<< 'usage: backup.sh <bucket>...'
  refute [ -e "$tree/rclone.log" ]
  refute [ -L "$tree/rclone.log" ]
}
