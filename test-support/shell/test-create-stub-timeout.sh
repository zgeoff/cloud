#!/usr/bin/env bash
# Test for create-stub-timeout.sh: the timeout stand-in runs the command after the duration and
# passes its exit code back, logs its argv only when a case names a log, exits 124 or 137 without
# running the command when a case expires it, as coreutils' timeout does for a command its TERM or
# its KILL ends, and fails closed on a call without a duration. Those two cases also pin each code
# against the real timeout.
#
#   bash test-support/shell/test-create-stub-timeout.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-timeout.sh"

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_timeout "$tree/bin"
}

it_runs_the_command_and_passes_its_exit_code_back() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TIMEOUT_LOG="$tree/calls" \
    timeout -k 5 20 bash -c 'echo ran; exit 3' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'ran'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["timeout","-k","5","20","bash","-c","echo ran; exit 3"]'
  assert_status 3 "$status"
}

it_logs_nothing_when_no_log_is_named() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout 20 true) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(ls -A "$tree") << 'EOF'
bin
err
home
out
tmp
EOF
  assert_status 0 "$status"
}

it_exits_124_without_running_the_command_when_expired_as_the_real_timeout_does() {
  local status=0 real=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TIMEOUT_LOG="$tree/calls" \
    STUB_TIMEOUT_EXPIRE=124 timeout 20 bash -c "touch '$tree/ran'" > "$tree/out" 2> "$tree/err" || status=$?
  /usr/bin/timeout 0.1 sleep 5 || real=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ ! -e "$tree/ran" ] || {
    echo "it ran the command" >&2
    exit 1
  }
  [ "$real" = 124 ] || {
    echo "the real timeout exited $real, want 124" >&2
    exit 1
  }
  assert_status 124 "$status"
}

it_exits_137_without_running_the_command_when_expired_past_the_kill_as_the_real_timeout_does() {
  local status=0 real=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TIMEOUT_EXPIRE=137 timeout -k 5 20 bash -c "touch '$tree/ran'" > "$tree/out" 2> "$tree/err" || status=$?
  /usr/bin/timeout -k 0.2 0.1 bash -c "trap '' TERM; exec sleep 5" || real=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ ! -e "$tree/ran" ] || {
    echo "it ran the command" >&2
    exit 1
  }
  [ "$real" = 137 ] || {
    echo "the real timeout exited $real, want 137" >&2
    exit 1
  }
  assert_status 137 "$status"
}

it_fails_closed_with_exit_97_on_a_call_without_a_duration() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout --signal=KILL 20 true > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: --signal=KILL 20 true'
  assert_status 97 "$status"
}

run_cases
