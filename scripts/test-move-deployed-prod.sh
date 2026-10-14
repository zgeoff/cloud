#!/usr/bin/env bash
# Test for move-deployed-prod.sh: it moves the repository's deployed/prod tag with one gh api
# PATCH that never forces, then prints the moved line and appends it to the step summary; a
# refused move fails with gh's status and writes no summary; a missing argument or GitHub
# variable fails before gh runs. gh is a stand-in (create-stub-deploy-tag-gh.sh). Each case runs
# the script under `env -i` and compares its whole stdout, stderr, gh call log and summary.
#
#   bash scripts/test-move-deployed-prod.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-deploy-tag-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/move-deployed-prod.sh"

it_moves_the_tag_without_force_and_writes_the_summary() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '## earlier step' > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'deployed/prod moved to 3333333333333333333333333333333333333333.'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  diff - "$tree/summary" << 'EOF'
## earlier step
deployed/prod moved to 3333333333333333333333333333333333333333.
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_ghs_status_and_writes_no_summary_when_github_refuses_the_move() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  : > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=gh-token STUB_TAG_MOVE=refused \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Update is not a fast forward (HTTP 422)'
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  diff /dev/null "$tree/summary"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_before_gh_runs_without_a_repository() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  : > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=gh-token \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 17: GITHUB_REPOSITORY: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_before_gh_runs_without_a_step_summary() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" 3333333333333333333333333333333333333333 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 17: GITHUB_STEP_SUMMARY: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_rejects_a_missing_revision_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  : > "$tree/summary"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: move-deployed-prod.sh <revision>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_deploy_tag_gh "$tree/bin"
}

run_cases
