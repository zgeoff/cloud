#!/usr/bin/env bash
# Test for create-stub-scripted-command.sh: the stand-in answers each call in turn from its
# script of answers, with that call's stdout, stderr and status, logs every call with its working
# directory, and fails closed with exit 97 on a call the script has no answer for.
#
#   bash test-support/shell/test-create-stub-scripted-command.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-scripted-command.sh"

it_answers_each_call_in_turn_with_its_own_output_and_status() {
  local status1=0 status2=0
  create_case_tree
  setup_test "$tree"
  printf 'first out\n' > "$tree/answers/1.out"
  printf 'first err\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"
  printf 'second out\n' > "$tree/answers/2.out"

  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" pulumi preview --refresh) > "$tree/out1" 2> "$tree/err1" || status1=$?
  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" pulumi preview --refresh) > "$tree/out2" 2> "$tree/err2" || status2=$?

  diff - "$tree/out1" <<< 'first out'
  diff - "$tree/err1" <<< 'first err'
  diff - "$tree/out2" <<< 'second out'
  diff /dev/null "$tree/err2"
  diff - "$tree/calls" << EOF
{"cwd":"$tree/work","argv":["pulumi","preview","--refresh"]}
{"cwd":"$tree/work","argv":["pulumi","preview","--refresh"]}
EOF
  [ "$status1" = 7 ] || {
    echo "first exit $status1, want 7" >&2
    exit 1
  }
  [ "$status2" = 0 ] || {
    echo "second exit $status2, want 0" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_a_call_with_no_answer() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" pulumi up --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: call 1: up --yes'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"pulumi\",\"up\",\"--yes\"]}"
  assert_status 97 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work" "$tree/answers"
  create_stub_scripted_command "$tree/bin" pulumi
}

run_cases
