#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-checks-git.sh: the git stand-in answers the two calls run-nixos-checks.sh makes,
# prints the toplevel as git does and the file list byte for byte, logs every call, and fails
# closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-checks-git.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it prints the toplevel with a newline and logs the call" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    git rev-parse --show-toplevel

  assert_output "$tree/repo"
  refute_stderr
  diff - "$tree/calls" <<< '["git","rev-parse","--show-toplevel"]'
}

@test "it prints the nul separated file list unchanged for the toplevels ls files" {
  setup_test "$tree"
  printf 'flake.nix\0scripts/a b.sh\0' > "$tree/ls-files"

  # to a file, so the NUL bytes reach the comparison
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    STUB_LS_FILES="$tree/ls-files" \
    git -C "$tree/repo" ls-files -z --cached --others --exclude-standard --deduplicate > "$tree/out" 2> "$tree/err"

  cmp "$tree/ls-files" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"git\",\"-C\",\"$tree/repo\",\"ls-files\",\"-z\",\"--cached\",\"--others\",\"--exclude-standard\",\"--deduplicate\"]"
}

@test "it fails closed with exit 97 on ls files for another directory" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_TOPLEVEL="$tree/repo" \
    git -C "$tree/other" ls-files -z --cached --others --exclude-standard --deduplicate

  refute_output
  assert_stderr "unexpected: -C $tree/other ls-files -z --cached --others --exclude-standard --deduplicate"
  diff - "$tree/calls" <<< "[\"git\",\"-C\",\"$tree/other\",\"ls-files\",\"-z\",\"--cached\",\"--others\",\"--exclude-standard\",\"--deduplicate\"]"
}
