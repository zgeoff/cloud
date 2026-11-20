#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for wait-for-k3s-api.sh: it returns once k3s's /livez answers, pausing 2 s after each try
# that does not, and fails naming the API after 30 tries. curl is a stand-in for geoffcloud's API
# (create-stub-livez-curl.sh), and the pause is the fake clock's (create-stub-clock.sh), first on
# PATH as sleep, so a case counts pauses instead of waiting them out. Each case runs the script
# under `env -i` and compares its whole stdout, stderr, curl call log and pauses.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-livez-curl.sh'
  load 'src/test-utils/shell/create-stub-clock.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/wait-for-k3s-api.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_livez_curl "$tree/bin"
  create_stub_clock "$tree/clock"
}

@test "it returns at once when the first try answers" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=1 \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
  refute [ -e "$tree/clock/pauses" ]
  refute [ -L "$tree/clock/pauses" ]
}

@test "it pauses 2 seconds after each try that does not answer" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=3 \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
EOF
  run -0 diff - "$tree/clock/pauses" << 'EOF'
2
2
EOF
}

@test "it returns when the last of 30 tries answers" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=30 \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - <(wc -l < "$tree/calls") <<< 30
  run -0 diff - <(wc -l < "$tree/clock/pauses") <<< 29
}

@test "it fails naming the api after 30 tries that do not answer" {
  setup_test "$tree"
  for _ in $(seq 1 30); do
    echo '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]' >> "$tree/want-calls"
    echo 2 >> "$tree/want-pauses"
  done

  run -1 --separate-stderr env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script"

  refute_output
  assert_stderr "k3s's API on geoffcloud:6443 did not answer"

  run -0 diff "$tree/want-calls" "$tree/calls"
  run -0 diff "$tree/want-pauses" "$tree/clock/pauses"
}
