#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-racing-restic.sh: the restic stand-in runs its race script once, right
# before the first `restore` call, then hands that call on (or, when the script fails, passes its
# status through and runs nothing), and hands every other call to the real restic unchanged. echo
# and false stand in for the real restic, so the cases read what reached it.
#
#   bash scripts/run-bats.sh
# shellcheck disable=SC2016 # each race script expands when the stand-in runs it

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-racing-restic.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-in in <tree>/bin, handing calls to <real restic>, with its
# race script at <tree>/race.sh and its state folder at <tree>/state.
setup_test() {
  local tree="$1" real_restic="$2"
  mkdir "$tree/bin" "$tree/state"
  create_stub_racing_restic "$tree/bin" "$real_restic" "$tree/race.sh" "$tree/state"
}

# run_stub <tree> <arg>...: the stand-in, run as the restore script runs restic
run_stub() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" restic "$@"
}

# restore_twice: two restores in a row
restore_twice() {
  run_stub "$tree" restore latest --tag set-2 --target /tmp/copy
  run_stub "$tree" restore latest --tag set-3 --target /tmp/copy
}

@test "it runs the race script once before the first restore then hands each call on" {
  setup_test "$tree" /bin/echo
  echo 'echo raced >> "$(dirname "$0")/races"' > "$tree/race.sh"

  run -0 --separate-stderr restore_twice

  assert_output - << 'EOF'
restore latest --tag set-2 --target /tmp/copy
restore latest --tag set-3 --target /tmp/copy
EOF
  refute_stderr
  diff - "$tree/races" <<< raced
  diff - "$tree/state/log" <<< '["restic-raced"]'
}

@test "it passes a failed race scripts status through and runs no restic" {
  setup_test "$tree" /bin/echo
  echo 'echo "race failed" >&2; exit 3' > "$tree/race.sh"

  run -3 --separate-stderr run_stub "$tree" restore latest --target /tmp/copy

  refute_output
  assert_stderr 'race failed'
  refute [ -e "$tree/state/log" ]
  refute [ -L "$tree/state/log" ]
}

@test "it hands every other call to the real restic unchanged" {
  setup_test "$tree" /bin/echo
  echo 'echo raced >> "$(dirname "$0")/races"' > "$tree/race.sh"

  run -0 --separate-stderr run_stub "$tree" snapshots --json

  assert_output 'snapshots --json'
  refute_stderr
  refute [ -e "$tree/races" ]
  refute [ -L "$tree/races" ]
  refute [ -e "$tree/state/log" ]
  refute [ -L "$tree/state/log" ]
}

@test "it passes the real restics exit code through" {
  setup_test "$tree" /bin/false
  : > "$tree/race.sh"

  run -1 --separate-stderr run_stub "$tree" restore latest --target /tmp/copy

  refute_output
  refute_stderr
}
