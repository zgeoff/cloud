#!/usr/bin/env bash
# Test for create-stub-runs-gh.sh: the gh stand-in logs each call, prints the runs a case names
# or, with none named, one run for the HEAD of the repository it runs in, answers with the error
# and exit a case names, and fails closed on any other call. No gh runs here; the exit codes come
# from gh's manual, as the stand-in's header records.
#
#   bash scripts/test-lib/test-create-stub-runs-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-runs-gh.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_prints_the_runs_the_case_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_RUNS='aaaa https://example.invalid/2
bbbb https://example.invalid/1' \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs' -f branch=main) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
aaaa https://example.invalid/2
bbbb https://example.invalid/1
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_for_an_empty_list_of_runs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_RUNS= \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs' -f branch=main) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_one_run_for_head_when_the_case_names_no_runs() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs' -f branch=main) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "$commit https://github.com/zgeoff/cloud/actions/runs/1"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main"]'
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_RUNS='aaaa https://example.invalid/1' \
    STUB_GH_ERROR='To get started with GitHub CLI, please run:  gh auth login' STUB_GH_EXIT=4 \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs') \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs"]'
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_GH_ERROR='gh: Not Found (HTTP 404)' \
    gh api -X GET 'repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs') \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs"]'
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" gh run list) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run list'
  diff - "$tree/calls" <<< '["gh","run","list"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

# Runtime every case needs: the stand-in, and a git repository with an empty root commit for it to
# run in, since the stand-in's default answer reads HEAD.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_runs_gh "$tree/bin"
  git -C "$tree/repo" init -q -b main
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
