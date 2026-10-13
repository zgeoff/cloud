#!/usr/bin/env bash
# Test for bump-releases.sh: in a real git repository in the case tree, it hands each BUMPS line to
# bump-release.sh in order, each in its own Actions group and from a tree reset hard and cleaned of
# what the bump before it left, with no stdin to read the lines still to come; it runs every line
# after a failed bump, marks that bump with an Actions error and then fails; and it fails without
# BUMPS. bump-releases.sh runs from a copy in the case tree beside the bump-release.sh stand-in
# (scripts/test-lib/create-stub-bump-release.sh). Each case runs it under `env -i` with git's
# global and system config off, and compares its whole stdout, stderr and the stand-in's log.
#
#   bash scripts/test-bump-releases.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-bump-release.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bump-releases.sh"

it_runs_each_bump_in_its_own_group_from_a_clean_tree() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" BUMPS='atc 4.3.0 4.3.0 4.2.0 4.3.0
imp 1.0.1 1.0.0 1.0.0' bash "$tree/scripts/bump-releases.sh") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
::group::atc 4.3.0
bumped atc
::endgroup::
::group::imp 1.0.1
bumped imp
::endgroup::
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["bump-release.sh","atc","4.3.0","4.3.0","4.2.0","4.3.0"]
{"status":""}
{"stdin":""}
["bump-release.sh","imp","1.0.1","1.0.0","1.0.0"]
{"status":""}
{"stdin":""}
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_runs_every_bump_after_a_failed_one_then_fails_naming_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" STUB_FAILING=atc BUMPS='atc 4.3.0 4.3.0 4.2.0 4.3.0
nixie 0.7.0 0.6.2 0.6.2' bash "$tree/scripts/bump-releases.sh") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
::group::atc 4.3.0
bumped atc
::error::the atc bump failed
::endgroup::
::group::nixie 0.7.0
bumped nixie
::endgroup::
EOF
  diff - "$tree/err" <<< 'the atc pin failed'
  diff - "$tree/calls" << 'EOF'
["bump-release.sh","atc","4.3.0","4.3.0","4.2.0","4.3.0"]
{"status":""}
{"stdin":""}
["bump-release.sh","nixie","0.7.0","0.6.2","0.6.2"]
{"status":""}
{"stdin":""}
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_without_bumps() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" bash "$tree/scripts/bump-releases.sh") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/scripts/bump-releases.sh: line 14: BUMPS: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: a copy of bump-releases.sh in <tree>/scripts beside the bump-release.sh
# stand-in, the home and temp folders it runs with, and <tree>/repo, a repository whose one commit
# holds the tracked file the stand-in changes.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/scripts" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  cp "$script" "$tree/scripts/bump-releases.sh"
  create_stub_bump_release "$tree/scripts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" init -q -b main
  # boot data: a tracked file the stand-in can leave changed
  echo pinned > "$tree/repo/pinned.txt"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" add pinned.txt
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'add the pin'
}

run_cases
