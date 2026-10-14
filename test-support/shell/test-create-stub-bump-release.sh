#!/usr/bin/env bash
# Test for create-stub-bump-release.sh: the bump-release.sh stand-in logs its argv, the working
# tree it found and its stdin, leaves the tree dirty and says what it bumped; it fails a dependency
# the case names; and it answers too few arguments with the same usage and exit as the real
# scripts/bump-release.sh.
#
#   bash test-support/shell/test-create-stub-bump-release.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-bump-release.sh"

real="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/bump-release.sh"

it_logs_its_call_and_the_tree_it_found_then_leaves_the_tree_dirty() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" bash "$tree/scripts/bump-release.sh" atc 4.3.0 4.2.0 \
    <<< 'imp 1.0.1 1.0.0 1.0.0') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'bumped atc'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["bump-release.sh","atc","4.3.0","4.2.0"]
{"status":""}
{"stdin":"imp 1.0.1 1.0.0 1.0.0"}
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" status --porcelain > "$tree/status"
  diff - "$tree/status" << 'EOF'
 M pinned.txt
?? left-over.txt
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_a_dependency_the_case_names_after_leaving_the_tree_dirty() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" STUB_FAILING='nixie atc' \
    bash "$tree/scripts/bump-release.sh" atc 4.3.0 4.2.0 < /dev/null) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'bumped atc'
  diff - "$tree/err" <<< 'the atc pin failed'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" status --porcelain > "$tree/status"
  diff - "$tree/status" << 'EOF'
 M pinned.txt
?? left-over.txt
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_answers_too_few_arguments_with_the_real_scripts_usage_and_exit() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$real" atc 4.3.0) > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$tree/scripts/bump-release.sh" atc 4.3.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: bump-release.sh <dependency> <version> <pinned version>...'
  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  diff /dev/null "$tree/calls"
  [ "$real_status" = 2 ] || {
    echo "the real script exited $real_status, want 2" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# setup_test <tree>: the stand-in in <tree>/scripts, the home and temp folders it runs with, and
# <tree>/repo, a repository whose one commit holds the tracked file the stand-in changes.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/scripts" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
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
