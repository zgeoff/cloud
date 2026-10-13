#!/usr/bin/env bash
# Test for label-release-bump.sh: it labels a bump with the largest step from an older pin, any
# review flags, and auto-merge or needs-review: a major update, a minor update to a 0.x release
# and any flag wait for a review; patch updates, and minor updates from 1.0 on, merge on their own.
#
#   bash scripts/test-label-release-bump.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"

script="$scripts/label-release-bump.sh"

# setup_test <tree>: the home and temp folders the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

it_lets_a_patch_update_merge_on_its_own() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.1 1.0.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:patch
auto-merge
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lets_a_minor_update_from_1_0_on_merge_on_its_own() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 4.3.0 4.2.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:minor
auto-merge
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_minor_update_to_a_0_x_release_for_review() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 0.8.0 0.7.0 0.7.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:minor
needs-review
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_major_update_for_review() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 5.0.0 4.3.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:major
needs-review
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_counts_0_9_to_1_0_as_a_major_update() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.0 0.9.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:major
needs-review
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_a_flag_and_holds_its_patch_update_for_review() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 0.7.1 0.7.0 0.7.0 -- sandbox-images-changed > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:patch
sandbox-images-changed
needs-review
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_labels_the_largest_step_across_the_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 4.3.0 4.2.0 2.26.2 4.3.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:major
needs-review
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_ignores_pins_at_the_version_or_newer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.1 1.0.1 2.0.0 1.0.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
update:patch
auto-merge
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_when_no_pin_is_older_than_the_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.1 1.0.1 1.1.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'no pinned version is older than 1.0.1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_pin_that_is_not_a_release_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.1 v1.0.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release version: 'v1.0.0'"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_prints_its_usage_without_a_pinned_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" 1.0.1 -- migrations > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: label-release-bump.sh <version> <pinned version>... [-- <flag>...]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
