#!/usr/bin/env bash
# Test for merge-release-bump-with-summary.sh: it runs merge-release-bump.sh, with the gh
# stand-in (test-support/shell/create-stub-release-gh.sh), and prints its decision on stdout and in
# the step summary; it fails with merge-release-bump.sh's own status and error when that fails,
# though tee succeeds; and it fails without a step summary file before running anything. Each case
# runs it under `env -i` and compares its whole stdout, stderr, step summary and gh call log.
#
#   bash scripts/test-merge-release-bump-with-summary.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/../test-support/shell/run-cases.sh"
source "$scripts/../test-support/shell/create-stub-release-gh.sh"

script="$scripts/merge-release-bump-with-summary.sh"

it_prints_the_merge_decision_and_copies_it_to_the_summary() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'release-check/atc has no open pull request'
  diff /dev/null "$tree/err"
  diff - "$tree/summary" <<< 'release-check/atc has no open pull request'
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_the_merge_scripts_status_and_error() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token MERGE_TOKEN=merge-token GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'APP_LOGIN must name the release check app, as app/<slug>'
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_fails_without_a_step_summary_file_before_running_anything() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 10: GITHUB_STEP_SUMMARY: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the script runs
# with, and the empty step summary the workflow's runner provides.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  # boot data: the runner creates the file before a step runs
  : > "$tree/summary"
  create_stub_release_gh "$tree/bin"
}

run_cases
