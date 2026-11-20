#!/usr/bin/env bats
# bats file_tags=suite:scripts
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/find-gate-base.sh"
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

# Runtime every case needs: the gh stand-in and an empty git repository.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
}

@test "it prints the newest green commit before the given one" {
  local older green head
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  older="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern alert'
  green="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" commit -q --allow-empty -m 'tune the lantern probe'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  # the lines the call's --jq filter prints, newest first: a re-run on the commit itself, a commit
  # this checkout lacks, then two green ancestors
  jq -cn --arg stdout "$head
0123456789abcdef0123456789abcdef01234567
$green
$older
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stdout: $stdout}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  assert_output "$green"
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
}

@test "it prints all zeros when no green run checked an ancestor" {
  local head
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  # the only green run checked the commit itself
  jq -cn --arg stdout "$head
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stdout: $stdout}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$head"

  assert_output '0000000000000000000000000000000000000000'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
}

@test "it fails with gh error and exit when gh fails" {
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  run -0 diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
}

@test "it refuses a commit git cannot resolve" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" 0123456789abcdef0123456789abcdef01234567

  refute_output
  assert_stderr 'find-gate-base: 0123456789abcdef0123456789abcdef01234567 is not a commit'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a missing argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script"

  refute_output
  assert_stderr 'usage: find-gate-base.sh <commit>'

  run -0 diff /dev/null "$tree/calls"
}
