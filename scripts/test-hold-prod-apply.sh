#!/usr/bin/env bash
# Test for hold-prod-apply.sh: it prints the error line that names the revision to dispatch and
# exits 1, and rejects a missing, empty or extra argument with its usage and exit 2. Each case
# runs the script under `env -i` and compares its whole stdout and stderr.
#
#   bash scripts/test-hold-prod-apply.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-prod-apply.sh"

it_prints_the_error_that_names_the_revision_to_dispatch_and_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 2222222222222222222222222222222222222222 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::error::The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision 2222222222222222222222222222222222222222.'
  diff /dev/null "$tree/err"
  assert_status 1 "$status"
}

it_rejects_a_missing_revision_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: hold-prod-apply.sh <revision>'
  assert_status 2 "$status"
}

it_rejects_an_empty_revision_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" '' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: hold-prod-apply.sh <revision>'
  assert_status 2 "$status"
}

it_rejects_an_extra_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 2222222222222222222222222222222222222222 extra > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: hold-prod-apply.sh <revision>'
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
}

run_cases
