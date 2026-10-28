#!/usr/bin/env bash
# Test for require-nixie-check.sh: it passes when nixie's API check succeeded, and fails with an
# error annotation that names the outcome for a failed, a cancelled or an empty one. Each case runs
# the script under `env -i` and compares its whole stdout and stderr.
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

it_passes_when_the_check_succeeded() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_CHECK=success \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "nixie's API check passed"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_fails_and_names_the_outcome_when_the_check_failed() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_CHECK=failure \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "::error::nixie's API check ended 'failure'; the apply job's step Check nixie's API logs why"
  diff /dev/null "$tree/err"
  assert_status 1 "$status"
}

it_fails_when_the_check_was_cancelled() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" NIXIE_CHECK=cancelled \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "::error::nixie's API check ended 'cancelled'; the apply job's step Check nixie's API logs why"
  assert_status 1 "$status"
}

it_fails_when_the_check_gave_no_outcome() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "::error::nixie's API check ended ''; the apply job's step Check nixie's API logs why"
  assert_status 1 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
}

run_cases
