#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for write-ci-pass-name.sh: in a real git repository whose HEAD is a merge commit, as a pull
# request's checkout is, it names the record after the merge commit's tree and its first parent's
# tree, in GITHUB_OUTPUT and in the given file, and gives its usage without a file. Each case runs
# the script under `env -i` with git's global and system config off.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/write-ci-pass-name.sh"
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

# setup_test <tree>: the home and temp folders the script runs with, the empty GITHUB_OUTPUT the
# runner provides, and <tree>/repo, an empty repository.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  # boot data: the runner creates the file before a step runs
  : > "$tree/output"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
}

@test "it names the record after the merge tree and its base tree" {
  local base_tree merge_tree
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/name"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" <<< "name=ci-pass-$merge_tree-$base_tree"
  run -0 diff - "$tree/name" <<< "ci-pass-$merge_tree-$base_tree"
}

@test "it fails with its usage without a file" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    bash "$script"

  refute_output
  assert_stderr 'usage: write-ci-pass-name.sh <file>'

  run -0 diff /dev/null "$tree/output"
}
