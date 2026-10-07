#!/usr/bin/env bash
# Test for assert-between.sh: assert_between passes a whole number within its bounds, both bounds
# included, and fails on any other value.
#
#   bash scripts/test-lib/test-assert-between.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-between.sh"

it_passes_silently_for_the_low_bound() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 1 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_silently_for_a_value_between_the_bounds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 5 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_silently_for_the_high_bound() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 9 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_below_the_range() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 0 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the label: expected 1..9, got 0'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_above_the_range() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 10 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the label: expected 1..9, got 10'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_an_empty_value() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 "" 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "the label: expected 1..9, got ''"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_a_value_that_is_not_a_whole_number() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  assert_between 1 "5.5" 9 "the label" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the label: expected 1..9, got 5.5'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
