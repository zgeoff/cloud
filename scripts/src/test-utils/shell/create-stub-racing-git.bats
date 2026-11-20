#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-racing-git.sh: the git stand-in answers `rev-parse origin/main` with
# the real git's answer, then lands a commit (or, when that rev-parse fails, passes its
# status through and lands nothing), and hands every other call to the real git
# unchanged.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-racing-git.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  # the suite's own git calls read no repository, user or system setting from the caller's
  # environment, and commit as a fixed identity
  while read -r name; do unset "$name"; done < <(compgen -e GIT_)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: a clone of a bare origin whose main holds one empty commit,
# the stand-in in <tree>/bin, racing against that clone, and the HOME and TMPDIR the
# stand-in's git runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  # no auto maintenance: a commit's, a fetch's or a push's detached repack could still write into
  # a repository while bats removes the case's tree
  git -C "$tree/origin.git" config maintenance.auto false
  git -C "$tree/clone" config maintenance.auto false
  git -C "$tree/clone" commit -q --allow-empty -m init
  git -C "$tree/clone" push -q origin main
  create_stub_racing_git "$tree/bin" "$(command -v git)" "$tree/clone" "$tree/calls"
}

@test "it answers rev parse origin main then lands a commit" {
  local checked
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  checked="$(git -C "$tree/clone" rev-parse HEAD)"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse origin/main

  assert_output "$checked"
  refute_stderr
  diff - "$tree/clone/nixos/marker" <<< moved
  git -C "$tree/clone" log --format=%s -2 > "$tree/log"
  diff - "$tree/log" << 'LOG'
moved
marker
LOG
  diff - "$tree/calls" <<< '["git-moved-head"]'
}

@test "it passes a failed rev parse origin main through and lands nothing" {
  local head
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" update-ref -d refs/remotes/origin/main
  head="$(git -C "$tree/clone" rev-parse HEAD)"

  run -128 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse origin/main

  assert_output origin/main
  assert_stderr - << 'ERR'
fatal: ambiguous argument 'origin/main': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
ERR
  git -C "$tree/clone" rev-parse HEAD > "$tree/head-after"
  diff - "$tree/head-after" <<< "$head"
  diff - "$tree/clone/nixos/marker" <<< committed
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
}

@test "it hands every other call to the real git unchanged" {
  local head
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  head="$(git -C "$tree/clone" rev-parse HEAD)"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse HEAD

  assert_output "$head"
  refute_stderr
  diff - "$tree/clone/nixos/marker" <<< committed
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
}

@test "it passes the real gits exit code through on other calls" {
  local head
  setup_test "$tree"
  head="$(git -C "$tree/clone" rev-parse HEAD)"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse --verify -q no-such-ref

  refute_output
  refute_stderr
  git -C "$tree/clone" rev-parse HEAD > "$tree/head-after"
  diff - "$tree/head-after" <<< "$head"
  refute [ -e "$tree/clone/nixos/marker" ]
  refute [ -L "$tree/clone/nixos/marker" ]
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
}
