#!/usr/bin/env bash
# Test for create-case-tree.sh: create_case_tree makes a fresh directory in the global tree and
# removes it when the shell exits, after the cleanup it is given, even when that cleanup fails.
# Each case runs the helper in a child bash, so the trap fires when that shell exits.
#
#   bash test-support/shell/test-create-case-tree.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"

helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/create-case-tree.sh"

it_makes_an_empty_directory_and_removes_it_at_exit() {
  local status=0 made
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # the child prints its tree, then proves it is an empty directory it can write in
  # shellcheck disable=SC2016 # the child bash expands its own script
  env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; create_case_tree; echo "$tree"; [ -d "$tree" ]; [ -z "$(ls -A "$tree")" ]; touch "$tree/file"' \
    _ "$helper" > "$tree/out" 2> "$tree/err" || status=$?

  made="$(cat "$tree/out")"
  [[ "$made" == "$tree"/tmp.* ]] || {
    echo "the tree was $made, want one under $tree" >&2
    exit 1
  }
  assert_missing "$made" "the tree after exit"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_runs_the_cleanup_first_reading_a_global_set_after_the_call() {
  local status=0 made
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # shellcheck disable=SC2016 # the child bash expands its own script
  env -i PATH=/usr/bin:/bin TMPDIR="$tree" LOG="$tree/log" bash -c \
    'set -e; source "$1"; create_case_tree '\''[ -d "$tree" ] && echo "cleanup $late" >> "$LOG" || true'\''; echo "$tree"; late=value' \
    _ "$helper" > "$tree/out" 2> "$tree/err" || status=$?

  made="$(cat "$tree/out")"
  diff - "$tree/log" <<< 'cleanup value'
  assert_missing "$made" "the tree after exit"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

# under errexit an unguarded failure would end the trap before rm, so a cleanup step ends || true
it_removes_the_tree_and_keeps_the_exit_status_when_a_cleanup_step_fails() {
  local status=0 made
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # shellcheck disable=SC2016 # the child bash expands its own script
  env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; create_case_tree "false || true"; echo "$tree"; exit 3' \
    _ "$helper" > "$tree/out" 2> "$tree/err" || status=$?

  made="$(cat "$tree/out")"
  assert_missing "$made" "the tree after exit"
  diff /dev/null "$tree/err"
  assert_status 3 "$status"
}

it_replaces_an_exit_trap_set_before_it() {
  local status=0 made
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # shellcheck disable=SC2016 # the child bash expands its own script
  env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; trap "echo earlier trap" EXIT; create_case_tree; echo "$tree"' \
    _ "$helper" > "$tree/out" 2> "$tree/err" || status=$?

  made="$(cat "$tree/out")"
  [[ "$made" == "$tree"/tmp.* ]] || {
    echo "the output was $made, want only the tree" >&2
    exit 1
  }
  assert_missing "$made" "the tree after exit"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

run_cases
