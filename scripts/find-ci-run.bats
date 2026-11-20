#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for find-ci-run.sh: against a real git repository in the case tree and a gh stand-in
# (scripts/src/test-utils/shell/create-stub-gh.sh) that replays the runs each case records, it asks for the
# green push runs on main of the exact commit, prints the first run's URL, prints nothing when no run is green, fails with gh's
# error and exit when gh fails, and refuses a commit git cannot resolve. Each case runs the script
# under `env -i` with git's global and system config off, and compares its whole stdout, stderr and
# gh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/find-ci-run.sh"
  # The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
  # system setting from the caller's environment, and commit as a fixed identity.
  while read -r name; do unset "$name"; done < <(compgen -e GIT_)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the gh stand-in, and a git repository with an empty root commit.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

@test "it prints the url of the green push run on the exact commit" {
  local commit
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'bump nixie'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # the lines the call's --jq filter prints: one run URL per green run, newest first
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/9\nhttps://github.com/zgeoff/cloud/actions/runs/8\n"}' \
    > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  assert_output 'https://github.com/zgeoff/cloud/actions/runs/9'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it prints nothing when no run on the commit is green" {
  local commit
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'bump nixie'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"]}' \
    > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$commit"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it fails with gh error and exit when gh fails" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn --arg commit "$commit" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($commit)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($commit)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$commit\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$commit\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it refuses a commit git cannot resolve" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" 0123456789abcdef0123456789abcdef01234567

  refute_output
  assert_stderr 'find-ci-run: 0123456789abcdef0123456789abcdef01234567 is not a commit'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a missing argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script"

  refute_output
  assert_stderr 'usage: find-ci-run.sh <commit>'

  run -0 diff /dev/null "$tree/calls"
}
