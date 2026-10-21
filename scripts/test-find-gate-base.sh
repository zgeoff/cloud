#!/usr/bin/env bash
#   bash scripts/test-find-gate-base.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find-gate-base.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_writes_the_newest_green_commit_before_the_given_one() {
  local green head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  green="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" commit -q --allow-empty -m 'tune the lantern probe'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  # the lines the call's --jq filter prints, newest first: a re-run on the commit itself, a commit
  # this checkout lacks, then the green ancestor
  jq -cn --arg stdout "$head
0123456789abcdef0123456789abcdef01234567
$green
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stdout: $stdout}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "base=$green"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< "base=$green"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
  assert_status 0 "$status"
}

it_writes_all_zeros_when_no_green_run_checked_an_ancestor() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  # the only green run checked the commit itself
  jq -cn --arg stdout "$head
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stdout: $stdout}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$head") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'base=0000000000000000000000000000000000000000'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'base=0000000000000000000000000000000000000000'
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
  assert_status 0 "$status"
}

it_fails_with_gh_error_and_exit_when_gh_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff /dev/null "$tree/output"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
  assert_status 4 "$status"
}

it_refuses_a_commit_git_cannot_resolve() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" 0123456789abcdef0123456789abcdef01234567) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'find-gate-base: 0123456789abcdef0123456789abcdef01234567 is not a commit'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_rejects_a_missing_output_file_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: GITHUB_OUTPUT=<file> find-gate-base.sh <commit>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# Runtime every case needs: the gh stand-in, an empty output file, and a git repository with an
# empty root commit.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  : > "$tree/output"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
