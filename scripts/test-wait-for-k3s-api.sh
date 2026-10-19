#!/usr/bin/env bash
# Test for wait-for-k3s-api.sh: it returns once k3s's /livez answers, pausing 2 s after each try
# that does not, and fails naming the API after 30 tries. curl is a stand-in for geoffcloud's API
# (create-stub-livez-curl.sh), and the pause is the fake clock's (create-stub-clock.sh), first on
# PATH as sleep, so a case counts pauses instead of waiting them out. Each case runs the script
# under `env -i` and compares its whole stdout, stderr, curl call log and pauses.
#
#   bash scripts/test-wait-for-k3s-api.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-livez-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wait-for-k3s-api.sh"

it_returns_at_once_when_the_first_try_answers() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=1 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]'
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  assert_status 0 "$status"
}

it_pauses_2_seconds_after_each_try_that_does_not_answer() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=3 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]
EOF
  diff - "$tree/clock/pauses" << 'EOF'
2
2
EOF
  assert_status 0 "$status"
}

it_returns_when_the_last_of_30_tries_answers() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_LIVEZ_ANSWER_FROM=30 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(wc -l < "$tree/calls") <<< 30
  diff - <(wc -l < "$tree/clock/pauses") <<< 29
  assert_status 0 "$status"
}

it_fails_naming_the_api_after_30_tries_that_do_not_answer() {
  local status=0
  create_case_tree
  setup_test "$tree"
  for _ in $(seq 1 30); do
    echo '["curl","-sk","-o","/dev/null","--max-time","5","https://geoffcloud:6443/livez"]' >> "$tree/want-calls"
    echo 2 >> "$tree/want-pauses"
  done

  env -i PATH="$tree/bin:$tree/clock:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "k3s's API on geoffcloud:6443 did not answer"
  diff "$tree/want-calls" "$tree/calls"
  diff "$tree/want-pauses" "$tree/clock/pauses"
  assert_status 1 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_livez_curl "$tree/bin"
  create_stub_clock "$tree/clock"
}

run_cases
