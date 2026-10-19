#!/usr/bin/env bash
# Test for move-deployed-prod.sh: it moves the repository's deployed/prod tag with one gh api
# PATCH that never forces, then prints the moved line and appends it to the step summary; a
# refused move fails with gh's status and writes no summary; a missing argument or GitHub
# variable fails before gh runs. gh is a stand-in (create-stub-gh.sh) that replays the answer each
# case records. Each case runs the script under `env -i` and compares its whole stdout, stderr, gh
# call log and summary.
#
# The recorded answers follow GitHub's "Update a reference" endpoint through gh api. They are not
# checked against GitHub or a real gh, since no test reaches GitHub. They were checked on
# 2026-10-14 against https://docs.github.com/en/rest/git/refs#update-a-reference (200 with the
# reference object, 422 "Validation failed, or the endpoint has been spammed") and
# https://cli.github.com/manual/gh_api (the response body goes to stdout; an HTTP error exits 1).
# The docs do not settle the 422 message for a move that is not a fast forward, nor gh's exact
# stderr line; the refused answer follows what GitHub's API answers in practice and needs a real
# sample.
#
#   bash scripts/test-move-deployed-prod.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/move-deployed-prod.sh"

it_moves_the_tag_without_force_and_writes_the_summary() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo '## earlier step' > "$tree/summary"
  # a move GitHub takes: the updated reference's JSON on stdout, exit 0
  cat > "$tree/gh-responses" << 'EOF'
{"argv": ["gh", "api", "--method", "PATCH", "repos/zgeoff/cloud/git/refs/tags/deployed/prod", "-f", "sha=3333333333333333333333333333333333333333", "-F", "force=false"], "stdout": "{\"ref\":\"refs/tags/deployed/prod\",\"url\":\"https://api.github.com/repos/zgeoff/cloud/git/refs/tags/deployed/prod\",\"object\":{\"sha\":\"3333333333333333333333333333333333333333\",\"type\":\"commit\",\"url\":\"https://api.github.com/repos/zgeoff/cloud/git/commits/3333333333333333333333333333333333333333\"}}\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'deployed/prod moved to 3333333333333333333333333333333333333333.'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  diff - "$tree/summary" << 'EOF'
## earlier step
deployed/prod moved to 3333333333333333333333333333333333333333.
EOF
  assert_status 0 "$status"
}

it_fails_with_ghs_status_and_writes_no_summary_when_github_refuses_the_move() {
  local status=0
  create_case_tree
  setup_test "$tree"
  : > "$tree/summary"
  # a move that is not a fast forward: GitHub's 422 body on stdout, gh's line on stderr, exit 1
  cat > "$tree/gh-responses" << 'EOF'
{"argv": ["gh", "api", "--method", "PATCH", "repos/zgeoff/cloud/git/refs/tags/deployed/prod", "-f", "sha=3333333333333333333333333333333333333333", "-F", "force=false"], "stdout": "{\"message\":\"Update is not a fast forward\",\"documentation_url\":\"https://docs.github.com/rest/git/refs#update-a-reference\",\"status\":\"422\"}\n", "stderr": "gh: Update is not a fast forward (HTTP 422)\n", "exit": 1}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Update is not a fast forward (HTTP 422)'
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  diff /dev/null "$tree/summary"
  assert_status 1 "$status"
}

it_fails_before_gh_runs_without_a_repository() {
  local status=0
  create_case_tree
  setup_test "$tree"
  : > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 17: GITHUB_REPOSITORY: parameter null or not set"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_before_gh_runs_without_a_step_summary() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 17: GITHUB_STEP_SUMMARY: parameter null or not set"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_rejects_a_missing_revision_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"
  : > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: move-deployed-prod.sh <revision>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

run_cases
