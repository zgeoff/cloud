#!/usr/bin/env bash
# Test for enable-atc-pin-auto-merge.sh: through the gh stand-in
# (scripts/test-lib/create-stub-release-gh.sh), it turns on squash auto-merge for the pull request
# in GITHUB_REPOSITORY, matched to the head it checked; it fails without GITHUB_REPOSITORY before
# calling gh; and a missing argument is a usage error. Each case runs it under `env -i` and
# compares its whole stdout, stderr and gh call log.
#
#   bash scripts/test-enable-atc-pin-auto-merge.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-release-gh.sh"

script="$scripts/enable-atc-pin-auto-merge.sh"

it_turns_on_squash_auto_merge_matched_to_the_checked_head() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=pr-token GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" 42 1111111111111111111111111111111111111111 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","merge","42","--repo","zgeoff/cloud","--auto","--squash","--match-head-commit","1111111111111111111111111111111111111111"]
EOF
  diff - "$tree/tokens" <<< pr-token
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_without_the_repository_before_calling_gh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=pr-token bash "$script" 42 1111111111111111111111111111111111111111 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 15: GITHUB_REPOSITORY: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_its_usage_without_the_head_sha() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=pr-token GITHUB_REPOSITORY=zgeoff/cloud bash "$script" 42 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: enable-atc-pin-auto-merge.sh <pr> <head sha>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, and the home and temp folders the script runs
# with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_release_gh "$tree/bin"
}

run_cases
