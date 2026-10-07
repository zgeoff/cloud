#!/usr/bin/env bash
# Test for assert-equals.sh: assert_equals passes equal strings silently and fails on different ones,
# printing both.
#
#   bash scripts/test-lib/test-assert-equals.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"

it_passes_silently_for_equal_strings() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_equals "a b" "a b" "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_for_different_strings_printing_both_quoted() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_equals "a b" "a c" "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the label: expected a\ b, got a\ c'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_an_empty_actual_string() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_equals "a" "" "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "the label: expected a, got ''"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
