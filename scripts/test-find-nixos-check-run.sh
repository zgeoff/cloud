#!/usr/bin/env bash
# Test for find-nixos-check-run.sh: against a real git repository in the case tree and a gh
# stand-in (test-support/shell/create-stub-gh.sh) that replays the green runs each case records,
# as the lines the call's --jq filter prints ("<head sha> <run url>" per run), it prints the URL
# of the newest run whose commit is the given commit or an ancestor with no input of the checks
# changed since, falls back to the green nixos check of the merged pull request that produced the
# commit when its head and the commit agree on the inputs of the checks, skips runs it cannot use,
# prints nothing when nothing covers the commit, and fails with gh's error and exit when gh fails. Each case runs the script under `env -i` with
# git's global and system config off, and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/test-find-nixos-check-run.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/gh-nixos-pr-calls.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find-nixos-check-run.sh"
# the real bun, which each case links into its stand-ins' directory, because the script runs
# run-decide-gates.ts with it
bun="$(command -v bun)"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_prints_the_url_of_a_green_run_on_the_commit_itself() {
  local commit status=0
  create_case_tree
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$commit") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/7
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_prints_the_newest_run_on_an_ancestor_when_no_input_changed_since() {
  local older newer status=0
  create_case_tree
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/9
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_prints_nothing_when_nixos_changed_since_the_newest_green_run() {
  local checked commit status=0
  create_case_tree
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_skips_a_run_on_a_commit_the_checkout_lacks_and_a_run_off_the_history_of_the_commit() {
  local checked side status=0
  create_case_tree
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" main) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/8
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_prints_nothing_when_gh_lists_no_green_run() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  # no green run: the --jq filter prints nothing
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]}' \
    > "$tree/gh-responses"
  commit="$(git -C "$tree/repo" rev-parse HEAD)"
  # and no merged pull request produced the commit
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_fails_with_the_exit_and_error_of_gh_when_gh_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{
    argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs",
      "-f", "branch=main", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 4 "$status"
}

it_fails_without_calling_gh_for_a_commit_git_cannot_resolve() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" no-such-commit) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'find-nixos-check-run: no-such-commit is not a commit'
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_rejects_a_call_without_one_commit_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: find-nixos-check-run.sh <commit>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
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
  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$1") > "$tree/out" 2> "$tree/err" || status=$?
}

main_runs_call='["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]'

it_prints_the_green_nixos_check_of_the_merged_pull_request_when_its_head_and_the_commit_agree() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  gh_check_runs_call "$head" | jq -c --arg url "$pull_url" '{argv: ., stdout: "\($url)\n"}' >> "$tree/gh-responses"

  run_script "$commit"

  diff - "$tree/out" <<< "$pull_url"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$main_runs_call
$(gh_pulls_call "$commit")
$(gh_check_runs_call "$head")
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_prints_nothing_when_the_pull_request_head_differs_from_the_commit_on_a_nixos_input() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ inputs = { }; }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  gh_check_runs_call "$head" | jq -c --arg url "$pull_url" '{argv: ., stdout: "\($url)\n"}' >> "$tree/gh-responses"

  run_script "$commit"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_prints_nothing_when_no_pull_request_has_the_commit_as_its_merge_commit() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  # the --jq filter keeps only a pull request whose merge_commit_sha is the commit, so another
  # pull request that holds the commit leaves nothing
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run_script "$commit"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$main_runs_call
$(gh_pulls_call "$commit")
EOF
  assert_status 0 "$status"
}

it_prints_nothing_when_the_nixos_check_of_the_pull_request_is_not_green() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c --arg pull "7 $head" '{argv: ., stdout: "\($pull)\n"}' >> "$tree/gh-responses"
  # no successful check run: the --jq filter prints nothing
  gh_check_runs_call "$head" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run_script "$commit"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_skips_a_pull_request_whose_head_it_cannot_fetch_and_says_so() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  # a head the checkout lacks, and no origin to fetch it from
  gh_pulls_call "$commit" | jq -c '{argv: ., stdout: "7 2222222222222222222222222222222222222222\n"}' \
    >> "$tree/gh-responses"

  run_script "$commit"

  diff /dev/null "$tree/out"
  grep -qx 'find-nixos-check-run: cannot fetch the head of pull request 7; skipping it' "$tree/err"
  assert_status 0 "$status"
}

it_prefers_a_run_on_main_and_makes_no_pull_request_call() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  jq -cn --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/9" --argjson argv "$main_runs_call" \
    '{argv: $argv, stdout: "\($runs)\n"}' > "$tree/gh-responses"

  run_script "$commit"

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/9
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$main_runs_call"
  assert_status 0 "$status"
}

it_fails_with_the_exit_and_error_of_gh_when_gh_fails_on_the_pull_request_lookup() {
  local commit head pull_url status=0
  create_case_tree
  setup_test "$tree"
  arrange_merged_pull_request '{ }'
  record_no_main_run
  gh_pulls_call "$commit" | jq -c '{argv: ., stderr: "HTTP 503: Service Unavailable\n", exit: 1}' \
    >> "$tree/gh-responses"

  run_script "$commit"

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'HTTP 503: Service Unavailable'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
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
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
