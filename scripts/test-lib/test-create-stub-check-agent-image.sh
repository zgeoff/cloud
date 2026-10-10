#!/usr/bin/env bash
# Test for create-stub-check-agent-image.sh: the check stand-in logs its argv, passes with
# "== 0 failed" and exit 0, and fails with the count a test sets and exit 1, as the real check
# reports.
#
#   bash scripts/test-lib/test-create-stub-check-agent-image.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-check-agent-image.sh"

# Runtime every case needs: the stand-in at <tree>/check-agent-image.sh, and the HOME and TMPDIR
# it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
  create_stub_check_agent_image "$tree/check-agent-image.sh"
}

it_passes_and_logs_its_arguments() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$tree/check-agent-image.sh" --imp agent-check-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== 0 failed'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["check-agent-image.sh","--imp","agent-check-abc1234"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_the_count_a_test_sets() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_CHECK_FAILURES=2 \
    bash "$tree/check-agent-image.sh" --imp agent-check-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== 2 failed'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["check-agent-image.sh","--imp","agent-check-abc1234"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
