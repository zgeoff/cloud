#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-case-tree.sh: create_case_tree makes a fresh directory in the global tree and
# removes it when the shell exits, after the cleanup it is given, even when that cleanup fails.
# Each case runs the helper in a child bash, so the trap fires when that shell exits.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  # a bash whose stdin is a socket reads ~/.bashrc, whose output would land in the stderr the cases check
  exec < /dev/null
  helper="$BATS_TEST_DIRNAME/create-case-tree.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

@test "it makes an empty directory and removes it at exit" {
  local made

  # the child prints its tree, then proves it is an empty directory it can write in
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; create_case_tree; echo "$tree"; [ -d "$tree" ]; [ -z "$(ls -A "$tree")" ]; touch "$tree/file"' \
    _ "$helper"

  made="$output"
  [[ "$made" == "$tree"/tmp.* ]]
  refute [ -e "$made" ]
  refute [ -L "$made" ]
  refute_stderr
}

@test "it runs the cleanup first reading a global set after the call" {
  local made

  # shellcheck disable=SC2016 # the child bash expands its own script
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin TMPDIR="$tree" LOG="$tree/log" bash -c \
    'set -e; source "$1"; create_case_tree '\''[ -d "$tree" ] && echo "cleanup $late" >> "$LOG" || true'\''; echo "$tree"; late=value' \
    _ "$helper"

  made="$output"
  diff - "$tree/log" <<< 'cleanup value'
  refute [ -e "$made" ]
  refute [ -L "$made" ]
  refute_stderr
}

# under errexit an unguarded failure would end the trap before rm, so a cleanup step ends || true
@test "it removes the tree and keeps the exit status when a cleanup step fails" {
  local made

  # shellcheck disable=SC2016 # the child bash expands its own script
  run -3 --separate-stderr env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; create_case_tree "false || true"; echo "$tree"; exit 3' \
    _ "$helper"

  made="$output"
  refute [ -e "$made" ]
  refute [ -L "$made" ]
  refute_stderr
}

@test "it replaces an exit trap set before it" {
  local made

  # shellcheck disable=SC2016 # the child bash expands its own script
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin TMPDIR="$tree" bash -c \
    'set -e; source "$1"; trap "echo earlier trap" EXIT; create_case_tree; echo "$tree"' \
    _ "$helper"

  made="$output"
  [[ "$made" == "$tree"/tmp.* ]]
  refute [ -e "$made" ]
  refute [ -L "$made" ]
  refute_stderr
}
