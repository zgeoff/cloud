#!/usr/bin/env bash
# Test for find-nixos-check-run.sh: against a real git repository in the case tree and a gh
# stand-in (scripts/test-lib/create-stub-runs-gh.sh) that lists the green runs, it prints the URL
# of the newest run whose commit is the given commit or an ancestor with no input of the checks
# changed since, skips runs it cannot use, prints nothing when no run covers the commit, and
# fails with gh's error and exit when gh fails. Each case runs the script under `env -i` with
# git's global and system config off, and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/test-find-nixos-check-run.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-runs-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/find-nixos-check-run.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_prints_the_url_of_a_green_run_on_the_commit_itself() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  commit="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_RUNS="$commit https://github.com/zgeoff/cloud/actions/runs/7" \
    bash "$script" "$commit") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/7
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_the_newest_run_on_an_ancestor_when_no_input_changed_since() {
  local older newer status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_RUNS="$newer https://github.com/zgeoff/cloud/actions/runs/9
$older https://github.com/zgeoff/cloud/actions/runs/8" \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/9
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_when_nixos_changed_since_the_newest_green_run() {
  local checked status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the flake'
  checked="$(git -C "$tree/repo" rev-parse HEAD)"
  echo changed >> "$tree/repo/nixos/flake.nix"
  git -C "$tree/repo" commit -qam 'change the flake'

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_RUNS="$checked https://github.com/zgeoff/cloud/actions/runs/8" \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_skips_a_run_on_a_commit_the_checkout_lacks_and_a_run_off_the_history_of_the_commit() {
  local checked side status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
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

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_RUNS="1111111111111111111111111111111111111111 https://github.com/zgeoff/cloud/actions/runs/11
$side https://github.com/zgeoff/cloud/actions/runs/10
$checked https://github.com/zgeoff/cloud/actions/runs/8" \
    bash "$script" main) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< https://github.com/zgeoff/cloud/actions/runs/8
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_when_gh_lists_no_green_run() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_RUNS= \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_the_exit_and_error_of_gh_when_gh_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_GH_ERROR='To get started with GitHub CLI, please run:  gh auth login' STUB_GH_EXIT=4 \
    bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 4 ] || {
    echo "exit $status, want 4" >&2
    exit 1
  }
}

it_fails_without_calling_gh_for_a_commit_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash "$script" no-such-commit) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'find-nixos-check-run: no-such-commit is not a commit'
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_rejects_a_call_without_one_commit_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: find-nixos-check-run.sh <commit>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# Runtime every case needs: the gh stand-in and a git repository on main. Each case commits the
# files its scenario starts from and names the runs gh lists.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_runs_gh "$tree/bin"
  git -C "$tree/repo" init -q -b main
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
