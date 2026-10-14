#!/usr/bin/env bash
# Test for run-with-file-modes.sh: run_with_file_modes runs a command with its arguments and
# returns its exit status, under the caller's uid, and the command meets a denied append, a
# denied create and a failed write test where the mode denies them, while a write the mode allows
# still succeeds. As root the denials prove the capabilities are gone; as any other user they
# prove the command runs unchanged. Each command runs under `env -i`, so its messages do not
# depend on the caller's locale.
#
#   bash test-support/shell/test-run-with-file-modes.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-with-file-modes.sh"

it_runs_the_command_with_its_arguments_and_returns_its_exit_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # shellcheck disable=SC2016 # expanded by the inner bash
  run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'printf "%s|" "$@"; exit 3' bash 'one two' three \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  printf '%s' 'one two|three|' | diff - "$tree/out"
  [ "$status" = 3 ] || {
    echo "exit $status, want 3" >&2
    exit 1
  }
}

it_keeps_the_callers_uid() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  id -u > "$tree/want"

  run_with_file_modes env -i PATH=/usr/bin:/bin id -u > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff "$tree/want" "$tree/out"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_denies_an_append_to_a_file_without_write_permission() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf '%s\n' 'first line' > "$tree/notes"
  chmod 0444 "$tree/notes"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'echo second line >> "$1"' bash "$tree/notes" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "bash: line 1: $tree/notes: Permission denied"
  diff - "$tree/notes" <<< 'first line'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_denies_a_create_in_a_directory_without_write_permission() {
  local status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+w "$tree" || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/locked"
  chmod 0500 "$tree/locked"

  run_with_file_modes env -i PATH=/usr/bin:/bin mktemp "$tree/locked/draft.XXXXXX" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "mktemp: failed to create file via template '$tree/locked/draft.XXXXXX': Permission denied"
  ls -A "$tree/locked" > "$tree/files"
  diff /dev/null "$tree/files"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_the_write_test_for_a_file_without_write_permission() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  touch "$tree/device"
  chmod 0400 "$tree/device"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run_with_file_modes env -i PATH=/usr/bin:/bin bash -c '[ -w "$1" ]' bash "$tree/device" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_lets_the_command_write_where_the_mode_allows_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf '%s\n' 'first line' > "$tree/notes"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'echo second line >> "$1" && echo new > "$2"' bash \
    "$tree/notes" "$tree/created" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/notes" << 'NOTES'
first line
second line
NOTES
  diff - "$tree/created" <<< new
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

run_cases
