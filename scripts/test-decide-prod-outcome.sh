#!/usr/bin/env bash
# Test for decide-prod-outcome.sh: it decides an apply of a plan the guard passes, ends a held plan
# on a push as held with a notice and a summary line that name the revision to dispatch and exit 0,
# decides an apply of a held plan on a manual dispatch, and fails on an empty or unknown verdict
# and on a missing variable. Each case runs the script under `env -i` and compares its whole
# stdout, stderr, step output and step summary.
#
#   bash scripts/test-decide-prod-outcome.sh
#   CASE='held' bash scripts/test-decide-prod-outcome.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-prod-outcome.sh"

it_decides_an_apply_of_a_plan_the_guard_passes_on_a_push() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=apply EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'outcome=apply'
  diff /dev/null "$tree/summary"
  assert_status 0 "$status"
}

it_ends_a_held_plan_on_a_push_as_held_and_names_the_revision_to_dispatch() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::notice::The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision 2222222222222222222222222222222222222222.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'outcome=held'
  diff - "$tree/summary" <<< 'The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision 2222222222222222222222222222222222222222.'
  assert_status 0 "$status"
}

it_decides_an_apply_of_a_held_plan_on_a_manual_dispatch() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_dispatch REVISION=2222222222222222222222222222222222222222 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'outcome=apply'
  diff /dev/null "$tree/summary"
  assert_status 0 "$status"
}

it_fails_when_the_guard_gave_no_verdict() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch REVISION=2222222222222222222222222222222222222222 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "decide-prod-outcome: the guard gave no verdict to act on: ''"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 1 "$status"
}

it_fails_on_a_verdict_it_does_not_know() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=Apply EVENT=workflow_run REVISION=2222222222222222222222222222222222222222 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "decide-prod-outcome: the guard gave no verdict to act on: 'Apply'"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 1 "$status"
}

it_refuses_a_missing_revision_as_a_usage_error() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    VERDICT=hold EVENT=workflow_run \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'decide-prod-outcome: set REVISION'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
  # boot data: the runner creates both files before a step runs
  : > "$tree/output"
  : > "$tree/summary"
}

run_cases
