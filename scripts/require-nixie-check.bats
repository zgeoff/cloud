#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for require-nixie-check.sh: it passes when nixie's API check and its prod doctor both
# succeeded, and fails with an error annotation that names each outcome other than success, a
# failed, a cancelled or an empty one. Each case runs the script under `env -i` and compares its
# whole stdout and stderr.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/require-nixie-check.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
}

@test "it passes when both checks succeeded" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=success \
    NIXIE_DOCTOR_CHECK=success bash "$script"

  assert_output - << 'OUT'
nixie's API check passed
nixie's prod doctor passed
OUT
  refute_stderr
}

@test "it fails and names the outcome when the api check failed" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=failure \
    NIXIE_DOCTOR_CHECK=success bash "$script"

  assert_output - << 'OUT'
::error::nixie's API check ended 'failure'; the apply job's step Check nixie's API logs why
nixie's prod doctor passed
OUT
  refute_stderr
}

@test "it fails and names the outcome when the doctor failed" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=success \
    NIXIE_DOCTOR_CHECK=failure bash "$script"

  assert_output - << 'OUT'
nixie's API check passed
::error::nixie's prod doctor ended 'failure'; the apply job's step Check nixie with its doctor logs why
OUT
  refute_stderr
}

@test "it fails when the checks were cancelled" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=cancelled \
    NIXIE_DOCTOR_CHECK=cancelled bash "$script"

  assert_output - << 'OUT'
::error::nixie's API check ended 'cancelled'; the apply job's step Check nixie's API logs why
::error::nixie's prod doctor ended 'cancelled'; the apply job's step Check nixie with its doctor logs why
OUT
}

@test "it fails when the checks gave no outcome" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script"

  assert_output - << 'OUT'
::error::nixie's API check ended ''; the apply job's step Check nixie's API logs why
::error::nixie's prod doctor ended ''; the apply job's step Check nixie with its doctor logs why
OUT
}
