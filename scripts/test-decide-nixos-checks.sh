#!/usr/bin/env bash
# Test for decide-nixos-checks.sh: against a real git repository in the case tree and a gh
# stand-in (test-support/shell/create-stub-gh.sh) that replays the green runs each case records,
# as the lines the call's --jq filter prints ("<head sha> <run url>" per run), it writes
# needed=true for any event but schedule without asking gh, needed=false with the summary line for
# a nightly run on a covered commit, needed=true for a nightly run on a commit no run covers, and
# fails with gh's error and writes nothing when gh fails. Each case runs the script under `env -i`
# with git's global and system config off, and compares its whole stdout, stderr, GITHUB_OUTPUT,
# step summary and gh call log.
#
#   bash scripts/test-decide-nixos-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-nixos-checks.sh"
# the real bun, which each case links into its stand-ins' directory, because the script runs
# decide-gates.ts with it through find-nixos-check-run.sh
bun="$(command -v bun)"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_needs_the_checks_for_a_dispatch_without_asking_gh() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'needed=true'
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_needs_the_checks_for_a_pull_request_without_asking_gh() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'needed=true'
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_skips_the_checks_for_a_nightly_run_on_a_covered_commit_and_says_so() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/7" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'needed=false'
  diff - "$tree/summary" <<< 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""]
EOF
  assert_status 0 "$status"
}

it_needs_the_checks_for_a_nightly_run_on_a_commit_no_run_covers() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""]}' \
    > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'needed=true'
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""]
EOF
  assert_status 0 "$status"
}

it_fails_with_the_gh_error_and_writes_nothing_when_gh_fails() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""],
    stderr: "HTTP 503: Service Unavailable\n", exit: 1}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'HTTP 503: Service Unavailable'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 1 "$status"
}

it_fails_without_a_github_output_file() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 13: GITHUB_OUTPUT: parameter null or not set"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the script runs
# with, the empty files the workflow's runner provides, and <tree>/repo, a repository with one
# commit to decide on.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  # boot data: the runner creates both files before a step runs
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  ln -s "$bun" "$tree/bin/bun"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves for the commit a case decides on
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
