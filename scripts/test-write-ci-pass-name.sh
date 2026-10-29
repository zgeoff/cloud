#!/usr/bin/env bash
# Test for write-ci-pass-name.sh: in a real git repository whose HEAD is a merge commit, as a pull
# request's checkout is, it names the record after the merge commit's tree and its first parent's
# tree, in GITHUB_OUTPUT and in the given file, and gives its usage without a file. Each case runs
# the script under `env -i` with git's global and system config off.
#
#   bash scripts/test-write-ci-pass-name.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-ci-pass-name.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_names_the_record_after_the_merge_tree_and_its_base_tree() {
  local base_tree merge_tree status=0
  create_case_tree
  setup_test "$tree"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'
  git -C "$tree/repo" checkout -qb wick
  echo 'wick' > "$tree/repo/wick.txt"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the wick'
  git -C "$tree/repo" checkout -q main
  echo '# lantern, tuned' > "$tree/repo/README.md"
  git -C "$tree/repo" commit -qam 'tune the lantern readme'
  base_tree="$(git -C "$tree/repo" rev-parse 'HEAD^{tree}')"
  git -C "$tree/repo" merge -q --no-edit wick
  merge_tree="$(git -C "$tree/repo" rev-parse 'HEAD^{tree}')"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/name") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< "name=ci-pass-$merge_tree-$base_tree"
  diff - "$tree/name" <<< "ci-pass-$merge_tree-$base_tree"
  assert_status 0 "$status"
}

it_fails_with_its_usage_without_a_file() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: write-ci-pass-name.sh <file>'
  diff /dev/null "$tree/output"
  assert_status 2 "$status"
}

# setup_test <tree>: the home and temp folders the script runs with, the empty GITHUB_OUTPUT the
# runner provides, and <tree>/repo, an empty repository.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  # boot data: the runner creates the file before a step runs
  : > "$tree/output"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
}

run_cases
