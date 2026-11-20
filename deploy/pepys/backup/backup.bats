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

  run -0 run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" facts blobs

  diff - "$tree/rclone.log" << 'EOF'
rclone copy garage:facts r2:pepys-backup/facts --checksum
rclone copy garage:blobs r2:pepys-backup/blobs --checksum
EOF
  assert_output - << 'EOF'
copied facts
copied blobs
EOF
}

@test "it stops at the first bucket that fails and copies no later one" {
  setup_test

  run -7 run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script" broken facts

  diff - "$tree/rclone.log" <<< 'rclone copy garage:broken r2:pepys-backup/broken --checksum'
}

@test "it refuses to run without a target bucket" {
  setup_test

  # the exit status of a failed ${name:?} expansion differs between shells
  run --separate-stderr run_backup_script sh "$script" facts

  assert_failure
  assert_stderr --partial 'set PEPYS_BACKUP_BUCKET'
  refute [ -e "$tree/rclone.log" ]
  refute [ -L "$tree/rclone.log" ]
}

@test "it refuses to run without a bucket to copy" {
  setup_test

  run -2 --separate-stderr run_backup_script PEPYS_BACKUP_BUCKET=pepys-backup sh "$script"

  assert_stderr 'usage: backup.sh <bucket>...'
  refute [ -e "$tree/rclone.log" ]
  refute [ -L "$tree/rclone.log" ]
}
