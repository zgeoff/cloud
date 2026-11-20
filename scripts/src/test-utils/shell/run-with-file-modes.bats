#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for run-with-file-modes.sh: run_with_file_modes runs a command with its arguments and
# returns its exit status, under the caller's uid, and the command meets a denied append, a
# denied create and a failed write test where the mode denies them, while a write the mode allows
# still succeeds. As root the denials prove the capabilities are gone; as any other user they
# prove the command runs unchanged. Each command runs under `env -i`, so its messages do not
# depend on the caller's locale.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'run-with-file-modes.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  # a bash whose stdin is a socket reads ~/.bashrc, whose output would land in the stderr the cases check
  exec < /dev/null
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  chmod -R u+w "$tree" || true
}

@test "it runs the command with its arguments and returns its exit status" {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run -3 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'printf "%s|" "$@"; exit 3' bash 'one two' three

  refute_stderr
  assert_output 'one two|three|'
}

@test "it keeps the callers uid" {
  run -0 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin id -u

  assert_output "$(id -u)"
  refute_stderr
}

@test "it denies an append to a file without write permission" {
  printf '%s\n' 'first line' > "$tree/notes"
  chmod 0444 "$tree/notes"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run -1 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'echo second line >> "$1"' bash "$tree/notes"

  refute_output
  assert_stderr "bash: line 1: $tree/notes: Permission denied"
  diff - "$tree/notes" <<< 'first line'
}

@test "it denies a create in a directory without write permission" {
  mkdir "$tree/locked"
  chmod 0500 "$tree/locked"

  run -1 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin mktemp "$tree/locked/draft.XXXXXX"

  refute_output
  # uutils mktemp names the file it tried, whose suffix is random, so the case masks it
  local masked gnu uutils
  masked="$(sed -E 's|(/locked/draft\.)[A-Za-z0-9]{6}"$|\1<random>"|' <<< "$stderr")"
  gnu="mktemp: failed to create file via template '$tree/locked/draft.XXXXXX': Permission denied"
  uutils="mktemp: Permission denied (os error 13) at path \"$tree/locked/draft.<random>\""
  [[ "$masked" == "$gnu" || "$masked" == "$uutils" ]] || fail "the denied mktemp matches neither GNU coreutils' output nor uutils coreutils 0.10.0's: $stderr"
  run -0 ls -A "$tree/locked"
  refute_output
}

@test "it fails the write test for a file without write permission" {
  touch "$tree/device"
  chmod 0400 "$tree/device"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run -1 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin bash -c '[ -w "$1" ]' bash "$tree/device"

  refute_output
  refute_stderr
}

@test "it lets the command write where the mode allows it" {
  printf '%s\n' 'first line' > "$tree/notes"

  # shellcheck disable=SC2016 # expanded by the inner bash
  run -0 --separate-stderr run_with_file_modes env -i PATH=/usr/bin:/bin bash -c 'echo second line >> "$1" && echo new > "$2"' bash \
    "$tree/notes" "$tree/created"

  refute_output
  refute_stderr
  diff - "$tree/notes" << 'NOTES'
first line
second line
NOTES
  diff - "$tree/created" <<< new
}
