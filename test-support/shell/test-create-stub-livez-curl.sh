#!/usr/bin/env bash
# Test for create-stub-livez-curl.sh: the curl stand-in times out (exit 28, nothing printed) on
# the tries before STUB_LIVEZ_ANSWER_FROM, answers from that try on, never answers without it,
# logs every call, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-livez-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-livez-curl.sh"

it_times_out_on_a_try_before_the_one_that_answers() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=2 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
  [ "$status" = 28 ] || {
    echo "exit $status, want 28" >&2
    exit 1
  }
}

it_answers_from_the_try_it_names_on() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'try\ntry\n' > "$tree/livez-tries"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=3 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
  diff - "$tree/livez-tries" << 'EOF'
try
try
try
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_never_answers_without_a_try_to_answer_from() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  for _ in $(seq 1 40); do echo try >> "$tree/livez-tries"; done

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 28 ] || {
    echo "exit $status, want 28" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=1 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/readyz > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -sk -o /dev/null --max-time 5 https://geoffcloud:6443/readyz'
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/readyz"]'
  [ ! -e "$tree/livez-tries" ] || {
    echo "the stand-in counted a try" >&2
    exit 1
  }
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_livez_curl "$tree/bin"
}

run_cases
