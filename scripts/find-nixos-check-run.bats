#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for find-nixos-check-run.sh: against a real git repository in the case tree and a gh
# stand-in (scripts/src/test-utils/shell/create-stub-gh.sh) that replays the green runs each case records,
# as the lines the call's --jq filter prints ("<head sha> <run url>" per run), it prints the URL
# of the newest run whose commit is the given commit or an ancestor with no input of the checks
# changed since, falls back to the green nixos check of the merged pull request that produced the
# commit when its head and the commit agree on the inputs of the checks, skips runs it cannot use,
# prints nothing when nothing covers the commit, and fails with gh's error and exit when gh fails. Each case runs the script under `env -i` with
# git's global and system config off, and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/run-bats.sh

# shellcheck disable=SC2030,SC2031 # arrange_merged_pull_request sets the case's own commit, head and pull_url

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  load 'src/test-utils/shell/gh-nixos-pr-calls.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/find-nixos-check-run.sh"
  # the real bun, which each case links into its stand-ins' directory, because the script runs
  # run-decide-gates.ts with it
  bun="$(command -v bun)"
  # The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
  # system setting from the caller's environment, and commit as a fixed identity.
  while read -r name; do unset "$name"; done < <(compgen -e GIT_)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
  main_runs_call='["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# A main commit that changes only docs, a merged pull request whose head carries the same NixOS
# inputs (or, with "differs", another flake), and the gh answers for them. Sets commit, head
# and pull_url; the case writes the answers for the calls it expects.
arrange_merged_pull_request() {
  local head_flake="$1"
  mkdir "$tree/repo/nixos" "$tree/repo/docs"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  git -C "$tree/repo" checkout -qb pull-7
  echo "$head_flake" > "$tree/repo/nixos/flake.nix"
  echo '# the pull request' > "$tree/repo/docs/pull.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the pull request head'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -q main
  mkdir -p "$tree/repo/docs"
  echo '# squashed' > "$tree/repo/docs/pull.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'squash the pull request'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  pull_url=https://github.com/zgeoff/cloud/actions/runs/70/job/1
}

# the answers for a lookup that finds no run on main
record_no_main_run() {
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]}' \
    >> "$tree/gh-responses"
}

run_script() {
  env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$1"
}

# Runtime every case needs: the gh stand-in and a git repository on main. Each case commits the
# files its scenario starts from and names the runs gh lists.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  ln -s "$bun" "$tree/bin/bun"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

@test "it prints the url of a green run on the commit itself" {
  local commit
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/7" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$commit"

  assert_output https://github.com/zgeoff/cloud/actions/runs/7
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it prints the newest run on an ancestor when no input changed since" {
  local older newer
  setup_test "$tree"
  mkdir "$tree/repo/nixos" "$tree/repo/docs"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  older="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '# notes' > "$tree/repo/docs/notes.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add notes'
  newer="$(git -C "$tree/repo" rev-parse HEAD)"
  echo changed >> "$tree/repo/docs/notes.md"
  git -C "$tree/repo" commit -qam 'change notes'
  jq -cn --arg runs "$newer https://github.com/zgeoff/cloud/actions/runs/9
$older https://github.com/zgeoff/cloud/actions/runs/8" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  assert_output https://github.com/zgeoff/cloud/actions/runs/9
  refute_stderr
}

@test "it prints nothing when nixos changed since the newest green run" {
  local checked commit
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  checked="$(git -C "$tree/repo" rev-parse HEAD)"
  echo changed >> "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" commit -qam 'change the flake'
  jq -cn --arg runs "$checked https://github.com/zgeoff/cloud/actions/runs/8" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # and no merged pull request produced the commit
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  refute_output
  refute_stderr
}

@test "it skips a run on a commit the checkout lacks and a run off the history of the commit" {
  local checked side
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  checked="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -qb side
  git -C "$tree/repo" commit -q --allow-empty -m 'a side commit'
  side="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -q main
  jq -cn --arg runs "1111111111111111111111111111111111111111 https://github.com/zgeoff/cloud/actions/runs/11
$side https://github.com/zgeoff/cloud/actions/runs/10
$checked https://github.com/zgeoff/cloud/actions/runs/8" '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" main

  assert_output https://github.com/zgeoff/cloud/actions/runs/8
  refute_stderr
}

@test "it prints nothing when gh lists no green run" {
  local tip
  setup_test "$tree"
  # no green run: the --jq filter prints nothing
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]}' \
    > "$tree/gh-responses"
  tip="$(git -C "$tree/repo" rev-parse HEAD)"
  # and no merged pull request produced the commit
  gh_pulls_call "$tip" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  refute_output
  refute_stderr
}

@test "it fails with the exit and error of gh when gh fails" {
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails without calling gh for a commit git cannot resolve" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" no-such-commit

  refute_output
  assert_stderr 'find-nixos-check-run: no-such-commit is not a commit'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a call without one commit with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script"

  refute_output
  assert_stderr 'usage: find-nixos-check-run.sh <commit>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it prints the green nixos check of the merged pull request when its head and the commit agree" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  gh_check_runs_call "$head" | jq -c --arg url "$pull_url" '{argv: ., stdout: "\($url)\n"}' >> "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  assert_output "$pull_url"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$main_runs_call
$(gh_pulls_call "$commit")
$(gh_check_runs_call "$head")
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it prints nothing when the pull request head differs from the commit on a nixos input" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ inputs = { }; }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  gh_check_runs_call "$head" | jq -c --arg url "$pull_url" '{argv: ., stdout: "\($url)\n"}' >> "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  refute_output
  refute_stderr
}

@test "it prints nothing when no pull request has the commit as its merge commit" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  # the --jq filter keeps only a pull request whose merge_commit_sha is the commit, so another
  # pull request that holds the commit leaves nothing
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$main_runs_call
$(gh_pulls_call "$commit")
EOF
}

@test "it prints nothing when the nixos check of the pull request is not green" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  # no successful check run: the --jq filter prints nothing
  gh_check_runs_call "$head" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  refute_output
  refute_stderr
}

@test "it skips a pull request whose head it cannot fetch and says so" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  # a head the checkout lacks, and no origin to fetch it from
  gh_pulls_call "$commit" | jq -c '{argv: ., stdout: "7 2222222222222222222222222222222222222222\n"}' \
    >> "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  refute_output
  assert_stderr_line 'find-nixos-check-run: cannot fetch the head of pull request 7; skipping it'
}

@test "it prefers a run on main and makes no pull request call" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/9" --argjson argv "$main_runs_call" \
    '{argv: $argv, stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr run_script "$commit"

  assert_output https://github.com/zgeoff/cloud/actions/runs/9
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$main_runs_call"
}

@test "it fails with the exit and error of gh when gh fails on the pull request lookup" {
  local commit head pull_url
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c '{argv: ., stderr: "HTTP 503: Service Unavailable\n", exit: 1}' \
    >> "$tree/gh-responses"

  run -1 --separate-stderr run_script "$commit"

  refute_output
  assert_stderr 'HTTP 503: Service Unavailable'

  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}
