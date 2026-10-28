#!/usr/bin/env bash
# Each case links the real bun into its stand-ins' directory, because the script runs
# run-decide-gates.ts with it, which reads the real .github/gates.yml.
#
#   bash scripts/test-decide-ci-gates.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-ci-gates.sh"
bun="$(command -v bun)"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_checks_a_cancelled_push_s_provider_change_on_a_later_docs_only_push() {
  local green status=0
  create_case_tree
  setup_test "$tree"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'
  green="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/provider"
  echo 'package main' > "$tree/repo/provider/main.go"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern provider'
  echo '# lantern, tuned' > "$tree/repo/README.md"
  git -C "$tree/repo" commit -qam 'tune the lantern readme'
  # the provider commit's run was cancelled, so only the first commit's run is green
  jq -cn --arg stdout "$green
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stdout: $stdout}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=push HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'provider=true
full=true'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'provider=true
full=true'
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
  assert_status 0 "$status"
}

it_compares_a_pull_request_with_its_base() {
  local base status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/repo/provider"
  echo 'package main' > "$tree/repo/provider/main.go"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern provider'
  base="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=pull_request PR_BASE="$base" \
    HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'provider=false
full=false
No input of the provider checks changed, so the Go checks did not run.
Only Markdown files changed, so the Nix-image linters and the shell suites did not run.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'provider=false
full=false'
  diff - "$tree/summary" <<< 'No input of the provider checks changed, so the Go checks did not run.
Only Markdown files changed, so the Nix-image linters and the shell suites did not run.'
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_fails_with_gh_error_and_exit_when_the_base_lookup_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=push HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 4 "$status"
}

it_rejects_a_pull_request_without_its_base_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=pull_request \
    HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: EVENT=<event> HEAD=<commit> [PR_BASE=<commit>] decide-ci-gates.sh <gate>...'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# Runtime every case needs: the gh stand-in, the real bun, empty GitHub files, and an empty git
# repository.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  ln -s "$bun" "$tree/bin/bun"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
}

run_cases
