#!/usr/bin/env bash
# Test for find-ci-run.sh: against a real git repository in the case tree and a gh stand-in
# (test-support/shell/create-stub-gh.sh) that replays the runs each case records, it asks for the
# green push runs on main of the exact commit, prints the first run's URL, prints nothing when no run is green, fails with gh's
# error and exit when gh fails, and refuses a commit git cannot resolve. Each case runs the script
# under `env -i` with git's global and system config off, and compares its whole stdout, stderr and
# gh call log.
#
#   bash scripts/test-find-ci-run.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find-ci-run.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_prints_the_url_of_the_green_push_run_on_the_exact_commit() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'bump nixie'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # the lines the call's --jq filter prints: one run URL per green run, newest first
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/9\nhttps://github.com/zgeoff/cloud/actions/runs/8\n"}' \
    > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/actions/runs/9'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_when_no_run_on_the_commit_is_green() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'bump nixie'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"]}' \
    > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$commit") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_gh_error_and_exit_when_gh_fails() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 4 ] || {
    echo "exit $status, want 4" >&2
    exit 1
  }
}

it_refuses_a_commit_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" 0123456789abcdef0123456789abcdef01234567) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'find-ci-run: 0123456789abcdef0123456789abcdef01234567 is not a commit'
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_rejects_a_missing_argument_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: find-ci-run.sh <commit>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# Runtime every case needs: the gh stand-in, and a git repository with an empty root commit.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
