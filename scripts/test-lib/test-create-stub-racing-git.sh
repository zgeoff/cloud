#!/usr/bin/env bash
# Test for create-stub-racing-git.sh: the git stand-in answers `rev-parse origin/main` with
# the real git's answer, then lands a commit (or, when that rev-parse fails, passes its
# status through and lands nothing), and hands every other call to the real git
# unchanged.
#
#   bash scripts/test-lib/test-create-stub-racing-git.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-racing-git.sh"

# The suite's own git calls read no repository, user or system setting from the caller's
# environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_answers_rev_parse_origin_main_then_lands_a_commit() {
  local checked status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  checked="$(git -C "$tree/clone" rev-parse HEAD)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse origin/main > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "$checked"
  diff /dev/null "$tree/err"
  diff - "$tree/clone/nixos/marker" <<< moved
  git -C "$tree/clone" log --format=%s -2 > "$tree/log"
  diff - "$tree/log" << 'LOG'
moved
marker
LOG
  diff - "$tree/calls" <<< '["git-moved-head"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_a_failed_rev_parse_origin_main_through_and_lands_nothing() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" update-ref -d refs/remotes/origin/main
  head="$(git -C "$tree/clone" rev-parse HEAD)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse origin/main > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< origin/main
  diff - "$tree/err" << 'ERR'
fatal: ambiguous argument 'origin/main': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
ERR
  git -C "$tree/clone" rev-parse HEAD > "$tree/head-after"
  diff - "$tree/head-after" <<< "$head"
  diff - "$tree/clone/nixos/marker" <<< committed
  assert_missing "$tree/calls" "the stand-in logged a move"
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_hands_every_other_call_to_the_real_git_unchanged() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  head="$(git -C "$tree/clone" rev-parse HEAD)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse HEAD > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "$head"
  diff /dev/null "$tree/err"
  diff - "$tree/clone/nixos/marker" <<< committed
  assert_missing "$tree/calls" "the stand-in logged a move"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_the_real_gits_exit_code_through_on_other_calls() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/clone" rev-parse --verify -q no-such-ref > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: a clone of a bare origin whose main holds one empty commit,
# the stand-in in <tree>/bin, racing against that clone, and the HOME and TMPDIR the
# stand-in's git runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  git -C "$tree/clone" commit -q --allow-empty -m init
  git -C "$tree/clone" push -q origin main
  create_stub_racing_git "$tree/bin" "$(command -v git)" "$tree/clone" "$tree/calls"
}

run_cases
