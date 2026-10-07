#!/usr/bin/env bash
# Test for assert-files-equal.sh: assert_files_equal passes equal files silently and fails on
# different ones, printing their diff.
#
#   bash scripts/test-lib/test-assert-files-equal.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-files-equal.sh"

it_passes_silently_for_equal_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'x\n' > "$tree/a"
  printf 'x\n' > "$tree/b"

  assert_files_equal "$tree/a" "$tree/b" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_for_different_files_printing_the_unified_diff() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  printf 'x\n' > "$tree/a"
  printf 'y\n' > "$tree/b"

  assert_files_equal "$tree/a" "$tree/b" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  # the two header lines carry the files' modification times
  sed -E '1,2s/\t.*$//' "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" << EOF
--- $tree/a
+++ $tree/b
@@ -1 +1 @@
-x
+y
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
