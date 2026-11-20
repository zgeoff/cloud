#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for decide-nixos-checks.sh: against a real git repository in the case tree and a gh
# stand-in (scripts/src/test-utils/shell/create-stub-gh.sh) that replays the green runs each case records,
# as the lines the call's --jq filter prints ("<head sha> <run url>" per run), it writes
# needed=true for a forced dispatch without asking gh, needed=false with the summary line for
# a nightly run or a dispatch on a covered commit, needed=true for a nightly run on a commit no run
# covers, and
# fails with gh's error and writes nothing when gh fails. Each case runs the script under `env -i`
# with git's global and system config off, and compares its whole stdout, stderr, GITHUB_OUTPUT,
# step summary and gh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  load 'src/test-utils/shell/gh-nixos-pr-calls.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/decide-nixos-checks.sh"
  # the real bun, which each case links into its stand-ins' directory, because the script runs
  # run-decide-gates.ts with it through find-nixos-check-run.sh
  bun="$(command -v bun)"
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
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves for the commit a case decides on
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

@test "it needs the checks for a forced dispatch without asking gh" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FORCE=true \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" <<< 'needed=true'
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it skips the checks for a dispatch on a covered commit and says so" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/7" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script"

  assert_output 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'needed=false'
  run -0 diff - "$tree/summary" <<< 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]
EOF
}

@test "it skips the checks for a nightly run on a covered commit and says so" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/7" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script"

  assert_output 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'needed=false'
  run -0 diff - "$tree/summary" <<< 'No input of the NixOS checks changed since https://github.com/zgeoff/cloud/actions/runs/7, so the checks did not run.'
  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]
EOF
}

@test "it needs the checks for a nightly run on a commit no run covers" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]}' \
    > "$tree/gh-responses"
  # and no merged pull request produced the commit
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" <<< 'needed=true'
  run -0 diff /dev/null "$tree/summary"
  {
    cat << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]
EOF
    gh_pulls_call "$commit"
  } > "$tree/want-calls"
  run -0 diff "$tree/want-calls" "$tree/calls"
}

@test "it fails with the gh error and writes nothing when gh fails" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stderr: "HTTP 503: Service Unavailable\n", exit: 1}' > "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" bash "$script"

  refute_output
  assert_stderr 'HTTP 503: Service Unavailable'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
}

@test "it fails without a github output file" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_SHA="$commit" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  refute_output
  assert_stderr "$script: line 14: GITHUB_OUTPUT: parameter null or not set"

  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}
