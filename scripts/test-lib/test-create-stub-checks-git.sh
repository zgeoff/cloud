#!/usr/bin/env bash
# Test for create-stub-checks-git.sh: the git stand-in answers the two calls test-nixos.sh makes,
# prints the toplevel as git does and the file list byte for byte, logs every call, and fails
# closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-checks-git.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-checks-git.sh"

it_prints_the_toplevel_with_a_newline_and_logs_the_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    git rev-parse --show-toplevel > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "$tree/repo"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["git","rev-parse","--show-toplevel"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_the_nul_separated_file_list_unchanged_for_the_toplevels_ls_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'flake.nix\0scripts/a b.sh\0' > "$tree/ls-files"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    STUB_LS_FILES="$tree/ls-files" \
    git -C "$tree/repo" ls-files -z --cached --others --exclude-standard --deduplicate \
    > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/ls-files" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"git\",\"-C\",\"$tree/repo\",\"ls-files\",\"-z\",\"--cached\",\"--others\",\"--exclude-standard\",\"--deduplicate\"]"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_ls_files_for_another_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    git -C "$tree/other" ls-files -z --cached --others --exclude-standard --deduplicate \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: -C $tree/other ls-files -z --cached --others --exclude-standard --deduplicate"
  diff - "$tree/calls" <<< "[\"git\",\"-C\",\"$tree/other\",\"ls-files\",\"-z\",\"--cached\",\"--others\",\"--exclude-standard\",\"--deduplicate\"]"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each call
# runs with. The empty call log is boot data: the stand-in appends to it, and a case
# compares it whole.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  create_stub_checks_git "$tree/bin"
}

run_cases
