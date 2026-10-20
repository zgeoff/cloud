#!/usr/bin/env bash
# Test for create-stub-scripted-command.sh: the stand-in answers each call in turn from its
# script of answers, with that call's stdout, stderr and status, logs every call with its working
# directory, logs the environment variables it is told to, takes its log and answers from paths it
# was given in place of the environment's, and fails closed with exit 97 on a call the script has
# no answer for.
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

it_logs_the_named_variables_that_the_call_s_environment_sets() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'done\n' > "$tree/answers/1.out"

  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_LOG_ENV='API_TOKEN EMPTY_VALUE WEBHOOK_URL' \
    API_TOKEN='tok en=1' EMPTY_VALUE= pulumi refresh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'done'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"pulumi\",\"refresh\"],\"env\":{\"API_TOKEN\":\"tok en=1\",\"EMPTY_VALUE\":\"\"}}"
  assert_status 0 "$status"
}

it_logs_to_and_answers_from_the_paths_it_was_given_in_place_of_the_environment_s() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/curl-answers"
  create_stub_scripted_command "$tree/bin" curl "$tree/curl-calls" "$tree/curl-answers"
  printf 'curl out\n' > "$tree/curl-answers/1.out"

  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" curl -fsS https://api.github.test) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'curl out'
  diff /dev/null "$tree/err"
  diff - "$tree/curl-calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"curl\",\"-fsS\",\"https://api.github.test\"]}"
  [ ! -e "$tree/calls" ] || {
    echo "it logged to STUB_LOG: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ ! -e "$tree/answers/count" ] || {
    echo "it counted in STUB_ANSWERS" >&2
    exit 1
  }
  assert_status 0 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work" "$tree/answers"
  create_stub_scripted_command "$tree/bin" pulumi
}

run_cases
