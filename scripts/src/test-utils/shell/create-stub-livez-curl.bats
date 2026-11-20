#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-livez-curl.sh: the curl stand-in times out (exit 28, nothing printed) on
# the tries before STUB_LIVEZ_ANSWER_FROM, answers from that try on, never answers without it,
# logs every call, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-livez-curl.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_livez_curl "$tree/bin"
}

@test "it times out on a try before the one that answers" {
  setup_test "$tree"

  run -28 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=2 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
}

@test "it answers from the try it names on" {
  setup_test "$tree"
  printf 'try\ntry\n' > "$tree/livez-tries"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=3 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
  diff - "$tree/livez-tries" << 'EOF'
try
try
try
EOF
}

@test "it never answers without a try to answer from" {
  setup_test "$tree"
  for _ in $(seq 1 40); do echo try >> "$tree/livez-tries"; done

  run -28 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez

  refute_output
  refute_stderr
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=1 \
    curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/readyz

  refute_output
  assert_stderr 'unexpected: -sk -o /dev/null --max-time 5 https://geoffcloud:6443/readyz'
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/readyz"]'
  refute [ -e "$tree/livez-tries" ]
}
