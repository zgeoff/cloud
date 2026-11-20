#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for decide-prod-outcome.sh: it decides an apply of a plan the guard passes, ends a held plan
# on a push as held with a notice and a summary line that name the revision to dispatch and exit 0,
# decides an apply of a held plan on a manual dispatch, and fails on an empty or unknown verdict
# and on a missing variable. Each case runs the script under `env -i` and compares its whole
# stdout, stderr, step output and step summary.
#
#   bash scripts/run-bats.sh
#   CASE='held' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/decide-prod-outcome.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
  # boot data: the runner creates both files before a step runs
  : > "$tree/output"
  : > "$tree/summary"
}

@test "it decides an apply of a plan the guard passes on a push" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=apply EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" <<< 'outcome=apply'
  run -0 diff /dev/null "$tree/summary"
}

@test "it ends a held plan on a push as held and names the revision to dispatch" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script"

  assert_output '::notice::The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision 2222222222222222222222222222222222222222.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'outcome=held'
  run -0 diff - "$tree/summary" <<< 'The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision 2222222222222222222222222222222222222222.'
}

@test "it decides an apply of a held plan on a manual dispatch" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_dispatch REVISION=2222222222222222222222222222222222222222 \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" <<< 'outcome=apply'
  run -0 diff /dev/null "$tree/summary"
}

@test "it fails when the guard gave no verdict" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch REVISION=2222222222222222222222222222222222222222 \
    bash "$script"

  refute_output
  assert_stderr "decide-prod-outcome: the guard gave no verdict to act on: ''"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
}

@test "it fails on a verdict it does not know" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=Apply EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script"

  refute_output
  assert_stderr "decide-prod-outcome: the guard gave no verdict to act on: 'Apply'"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
}

@test "it refuses a missing revision as a usage error" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_run \
    bash "$script"

  refute_output
  assert_stderr 'decide-prod-outcome: set REVISION'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
}
