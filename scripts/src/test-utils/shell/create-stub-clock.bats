#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-clock.sh: the fake clock starts at 0 and moves only when the fake
# pause runs, one second per pause, and the pause records each argument, also when it runs
# as the sleep command on PATH. Each command runs under `env -i` with PATH, HOME and TMPDIR
# set, HOME and TMPDIR inside the case tree.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-clock.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the clock and pause in <tree>, and the HOME and TMPDIR they run
# with.
setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
  create_stub_clock "$tree"
}

# read_clock_twice: the fake clock's two reads, one after the other
read_clock_twice() {
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"
}

@test "it reads 0 before any pause" {
  setup_test "$tree"

  run -0 env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"

  assert_output 0
  refute [ -e "$tree/pauses" ]
  refute [ -L "$tree/pauses" ]
}

@test "it advances one second for each pause and records its argument" {
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 0.05
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 2
  run -0 env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"

  assert_output 2
  diff - "$tree/pauses" << 'PAUSES'
0.05
2
PAUSES
}

@test "it keeps the time still between reads" {
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 0.05

  run -0 read_clock_twice

  assert_output - << 'READS'
1
1
READS
}

@test "it answers as the sleep command on PATH" {
  setup_test "$tree"

  env -i PATH="$tree:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" sleep 0.05
  run -0 env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"

  assert_output 1
  diff - "$tree/pauses" <<< 0.05
}
