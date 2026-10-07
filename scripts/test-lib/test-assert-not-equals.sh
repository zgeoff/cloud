#!/usr/bin/env bash
# Test for assert-not-equals.sh: assert_not_equals passes different strings silently and fails on
# equal ones, naming the value.
#
#   bash scripts/test-lib/test-assert-not-equals.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-not-equals.sh"

it_passes_silently_for_different_strings() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_not_equals "a b" "a c" "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_for_equal_strings_naming_the_value_quoted() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_not_equals "a b" "a b" "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the label: expected anything but a\ b'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
