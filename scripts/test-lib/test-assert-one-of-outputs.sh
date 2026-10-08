#!/usr/bin/env bash
# Test for assert-one-of-outputs.sh: assert_one_of_outputs passes an output that matches one
# supported candidate whole (stdout, stderr and exit status together), and fails, naming
# what differs from each candidate, on unknown text, on one candidate's text with another's
# status, and on one candidate's stdout with another's stderr.
#
#   bash scripts/test-lib/test-assert-one-of-outputs.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-one-of-outputs.sh"

it_passes_silently_for_the_first_candidate() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'old wording\n' > "$tree/err"
  printf 'old wording\n' > "$tree/err-v1"
  printf 'new wording\n' > "$tree/err-v2"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 125 \
    v1 /dev/null "$tree/err-v1" 125 \
    v2 /dev/null "$tree/err-v2" 1 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/assert-err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_silently_for_a_later_candidate() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'new wording\n' > "$tree/err"
  printf 'old wording\n' > "$tree/err-v1"
  printf 'new wording\n' > "$tree/err-v2"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 1 \
    v1 /dev/null "$tree/err-v1" 125 \
    v2 /dev/null "$tree/err-v2" 1 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/assert-err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_for_text_no_candidate_prints() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'other wording\n' > "$tree/err"
  printf 'old wording\n' > "$tree/err-v1"
  printf 'new wording\n' > "$tree/err-v2"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 1 \
    v1 /dev/null "$tree/err-v1" 125 \
    v2 /dev/null "$tree/err-v2" 1 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" << 'ERR'
the case: matches none of the supported outputs
--- stdout
--- stderr
other wording
--- exit 1
not v1: differs in stderr, exit 125
not v2: differs in stderr
ERR
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_one_candidates_text_with_another_candidates_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'old wording\n' > "$tree/err"
  printf 'old wording\n' > "$tree/err-v1"
  printf 'new wording\n' > "$tree/err-v2"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 1 \
    v1 /dev/null "$tree/err-v1" 125 \
    v2 /dev/null "$tree/err-v2" 1 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" << 'ERR'
the case: matches none of the supported outputs
--- stdout
--- stderr
old wording
--- exit 1
not v1: differs in exit 125
not v2: differs in stderr
ERR
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_one_candidates_stdout_with_another_candidates_stderr() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf '1.0\n' > "$tree/actual-out"
  printf 'new wording\n' > "$tree/actual-err"
  printf '1.0\n' > "$tree/out-v1"
  printf 'old wording\n' > "$tree/err-v1"
  printf '2.0\n' > "$tree/out-v2"
  printf 'new wording\n' > "$tree/err-v2"

  assert_one_of_outputs "the case" "$tree/actual-out" "$tree/actual-err" 1 \
    v1 "$tree/out-v1" "$tree/err-v1" 1 \
    v2 "$tree/out-v2" "$tree/err-v2" 1 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" << 'ERR'
the case: matches none of the supported outputs
--- stdout
1.0
--- stderr
new wording
--- exit 1
not v1: differs in stderr
not v2: differs in stdout
ERR
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_output_on_a_stream_a_candidate_expects_empty() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'stray\n' > "$tree/actual-out"
  printf 'old wording\n' > "$tree/err"
  printf 'old wording\n' > "$tree/err-v1"

  assert_one_of_outputs "the case" "$tree/actual-out" "$tree/err" 125 \
    v1 /dev/null "$tree/err-v1" 125 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" << 'ERR'
the case: matches none of the supported outputs
--- stdout
stray
--- stderr
old wording
--- exit 125
not v1: differs in stdout
ERR
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_for_an_actual_output_file_that_does_not_exist() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  : > "$tree/err-v1"

  assert_one_of_outputs "the case" /dev/null "$tree/missing" 0 \
    v1 /dev/null "$tree/err-v1" 0 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" << ERR
the case: matches none of the supported outputs
--- stdout
--- stderr
cat: $tree/missing: No such file or directory
--- exit 0
not v1: differs in stderr
ERR
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_call_without_a_whole_candidate() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  : > "$tree/err"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 0 \
    v1 /dev/null "$tree/err" > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" <<< 'assert_one_of_outputs: want <label> <stdout> <stderr> <status>, then <name> <stdout> <stderr> <status> for each supported output'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_refuses_a_call_without_any_candidate() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  : > "$tree/err"

  assert_one_of_outputs "the case" /dev/null "$tree/err" 0 > "$tree/out" 2> "$tree/assert-err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/assert-err" <<< 'assert_one_of_outputs: want <label> <stdout> <stderr> <status>, then <name> <stdout> <stderr> <status> for each supported output'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
