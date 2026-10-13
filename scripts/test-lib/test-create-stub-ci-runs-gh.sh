#!/usr/bin/env bash
# Test for create-stub-ci-runs-gh.sh: the gh stand-in logs each call, prints the runs a case names,
# prints nothing when a case names none, answers with the error and exit a case names, and fails
# closed on any other call. No gh runs here; the exit codes come from gh's manual, as the
# stand-in's header records.
#
#   bash scripts/test-lib/test-create-stub-ci-runs-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-ci-runs-gh.sh"

it_prints_the_runs_the_case_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_RUNS='https://example.invalid/2
https://example.invalid/1' \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/ci.yml/runs' -f event=push) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
https://example.invalid/2
https://example.invalid/1
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_when_the_case_names_no_runs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/ci.yml/runs' -f event=push) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_with_the_error_and_exit_the_case_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_RUNS='https://example.invalid/1' \
    STUB_GH_ERROR='To get started with GitHub CLI, please run:  gh auth login' STUB_GH_EXIT=4 \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/ci.yml/runs' -f event=push) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push"]'
  [ "$status" = 4 ] || {
    echo "exit $status, want 4" >&2
    exit 1
  }
}

it_exits_1_for_an_error_the_case_gives_no_exit_for() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_GH_ERROR='gh: Not Found (HTTP 404)' \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/ci.yml/runs' -f event=push) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_closed_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs' -f event=push) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api -X GET repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs -f event=push'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","event=push"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_ci_runs_gh "$tree/bin"
}

run_cases
