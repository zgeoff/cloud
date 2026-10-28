#!/usr/bin/env bash
# Test for check-nixos-checks-dispatch.sh: against a gh stand-in
# (test-support/shell/create-stub-gh.sh) that replays the pull request and check-run lookups each
# case records, as the lines their --jq filters print, it passes a nightly run and a dispatch on
# main without asking gh, refuses a run on main that names a pull request and a run on a branch
# that names none, passes a pull request's run at its head once CI's checks passed there, refuses
# one whose head moved or whose checks have not passed, and fails with gh's error. Each case runs
# the script under `env -i` and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/test-check-nixos-checks-dispatch.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-nixos-checks-dispatch.sh"

it_passes_a_nightly_run_without_asking_gh() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=schedule GITHUB_REF_NAME=main GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_passes_a_dispatch_on_main_without_asking_gh() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=main GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_refuses_a_dispatch_on_main_that_names_a_pull_request() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=main GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud PULL_REQUEST=412 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "check-nixos-checks-dispatch: a run on main checks main; dispatch pull request #412's run on its head branch with bun run ops:nixos-checks -- --pr 412"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_dispatch_on_a_branch_that_names_no_pull_request() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=lantern-unit GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "check-nixos-checks-dispatch: a run on lantern-unit checks its pull request's merge commit; dispatch it with bun run ops:nixos-checks -- --pr <number>"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_passes_a_pull_request_s_run_at_its_head_once_ci_s_checks_passed() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # GitHub's REST docs (pulls, get a pull request; checks, list check runs for a Git reference,
  # whose default filter keeps the latest run of each name; read 2026-10-28)
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","api","repos/zgeoff/cloud/pulls/412","--jq","\"\\(.state) \\(.head.ref) \\(.head.sha)\""], "stdout": "open lantern-unit 1111111111111111111111111111111111111111\n"}
{"argv": ["gh","api","-X","GET","repos/zgeoff/cloud/commits/1111111111111111111111111111111111111111/check-runs","-f","check_name=checks","--jq","[.check_runs[] | select(.app.slug == \"github-actions\")][0].conclusion // \"missing\""], "stdout": "success\n"}
JSON

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=lantern-unit GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud PULL_REQUEST=412 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","api","repos/zgeoff/cloud/pulls/412","--jq","\"\\(.state) \\(.head.ref) \\(.head.sha)\""]
["gh","api","-X","GET","repos/zgeoff/cloud/commits/1111111111111111111111111111111111111111/check-runs","-f","check_name=checks","--jq","[.check_runs[] | select(.app.slug == \"github-actions\")][0].conclusion // \"missing\""]
EOF
  assert_status 0 "$status"
}

it_refuses_a_pull_request_s_run_when_its_head_moved() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","api","repos/zgeoff/cloud/pulls/412","--jq","\"\\(.state) \\(.head.ref) \\(.head.sha)\""], "stdout": "open lantern-unit 2222222222222222222222222222222222222222\n"}
JSON

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=lantern-unit GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud PULL_REQUEST=412 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "check-nixos-checks-dispatch: pull request #412 is open at lantern-unit 2222222222222222222222222222222222222222, not open at lantern-unit 1111111111111111111111111111111111111111"
  assert_status 1 "$status"
}

it_refuses_a_pull_request_s_run_before_ci_s_checks_pass() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","api","repos/zgeoff/cloud/pulls/412","--jq","\"\\(.state) \\(.head.ref) \\(.head.sha)\""], "stdout": "open lantern-unit 1111111111111111111111111111111111111111\n"}
{"argv": ["gh","api","-X","GET","repos/zgeoff/cloud/commits/1111111111111111111111111111111111111111/check-runs","-f","check_name=checks","--jq","[.check_runs[] | select(.app.slug == \"github-actions\")][0].conclusion // \"missing\""], "stdout": "failure\n"}
JSON

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=lantern-unit GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud PULL_REQUEST=412 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "check-nixos-checks-dispatch: CI's checks on 1111111111111111111111111111111111111111 are failure; dispatch once they pass on the head you merge"
  assert_status 1 "$status"
}

it_fails_with_the_gh_error_when_the_pull_request_lookup_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","api","repos/zgeoff/cloud/pulls/412","--jq","\"\\(.state) \\(.head.ref) \\(.head.sha)\""], "stderr": "HTTP 404: Not Found\n", "exit": 1}
JSON

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=lantern-unit GITHUB_SHA=1111111111111111111111111111111111111111 \
    GITHUB_REPOSITORY=zgeoff/cloud PULL_REQUEST=412 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'HTTP 404: Not Found'
  assert_status 1 "$status"
}

# setup_test <tree>: the gh stand-in in <tree>/bin, and the home and temp folders the script runs
# with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

run_cases
