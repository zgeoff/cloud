#!/usr/bin/env bash
# Test for assert-status.sh: assert_status passes an equal exit status silently and fails on a
# different one, printing both.
#
#   bash test-support/shell/test-assert-status.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"

it_passes_silently_for_the_expected_status() {
  local status=0
  create_case_tree

  assert_status 3 3 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_for_another_status_printing_both() {
  local status=0
  create_case_tree

  assert_status 3 30 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'exit 30, want 3'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_for_an_empty_status() {
  local status=0
  create_case_tree

  assert_status 0 "" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'exit , want 0'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_ends_the_case_under_errexit_when_the_status_differs() {
  local status=0
  create_case_tree

  bash -c 'set -e; source "$1"; assert_status 0 2; echo after' _ \
    "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'exit 2, want 0'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

run_cases
