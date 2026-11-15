#!/usr/bin/env bash
# Test for require-nixie-check.sh: it passes when nixie's API check and its prod doctor both
# succeeded, and fails with an error annotation that names each outcome other than success, a
# failed, a cancelled or an empty one. Each case runs the script under `env -i` and compares its
# whole stdout and stderr.
#
#   bash scripts/test-require-nixie-check.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-nixie-check.sh"

it_passes_when_both_checks_succeeded() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=success \
    NIXIE_DOCTOR_CHECK=success bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
nixie's API check passed
nixie's prod doctor passed
OUT
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_fails_and_names_the_outcome_when_the_api_check_failed() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=failure \
    NIXIE_DOCTOR_CHECK=success bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
::error::nixie's API check ended 'failure'; the apply job's step Check nixie's API logs why
nixie's prod doctor passed
OUT
  diff /dev/null "$tree/err"
  assert_status 1 "$status"
}

it_fails_and_names_the_outcome_when_the_doctor_failed() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=success \
    NIXIE_DOCTOR_CHECK=failure bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
nixie's API check passed
::error::nixie's prod doctor ended 'failure'; the apply job's step Check nixie with its doctor logs why
OUT
  diff /dev/null "$tree/err"
  assert_status 1 "$status"
}

it_fails_when_the_checks_were_cancelled() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_API_CHECK=cancelled \
    NIXIE_DOCTOR_CHECK=cancelled bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
::error::nixie's API check ended 'cancelled'; the apply job's step Check nixie's API logs why
::error::nixie's prod doctor ended 'cancelled'; the apply job's step Check nixie with its doctor logs why
OUT
  assert_status 1 "$status"
}

it_fails_when_the_checks_gave_no_outcome() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
::error::nixie's API check ended ''; the apply job's step Check nixie's API logs why
::error::nixie's prod doctor ended ''; the apply job's step Check nixie with its doctor logs why
OUT
  assert_status 1 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
}

run_cases
