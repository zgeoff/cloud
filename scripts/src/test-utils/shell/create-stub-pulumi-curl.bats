#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-pulumi-curl.sh: the curl stand-in logs each call, writes a release file
# into the working directory for -O and prints one otherwise, answers a file the tree lacks as
# curl does for a 404 with -f, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-pulumi-curl.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# in_dir <dir> <command…>: runs the command from <dir>
in_dir() {
  cd "$1" && shift && "$@"
}

# setup_test <tree>: the stand-in in <tree>/bin, the HOME and TMPDIR it runs with, an empty
# working directory <tree>/work and an empty release directory. It sets case_env, the
# environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work" "$tree/pulumi"
  create_stub_pulumi_curl "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

@test "it writes the release file into the working directory for a named download" {
  setup_test "$tree"
  echo tarball > "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz"

  run -0 --separate-stderr in_dir "$tree/work" "${case_env[@]}" curl -fsSLO https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz

  refute_output
  refute_stderr
  diff - "$tree/work/pulumi-v1.2.3-linux-x64.tar.gz" <<< tarball
  diff - "$tree/calls" <<< '["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz"]'
}

@test "it prints the release file" {
  setup_test "$tree"
  echo 'abc  pulumi-v1.2.3-linux-x64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  run -0 --separate-stderr in_dir "$tree/work" "${case_env[@]}" curl -fsSL https://get.pulumi.com/releases/sdk/pulumi-1.2.3-checksums.txt

  assert_output 'abc  pulumi-v1.2.3-linux-x64.tar.gz'
  refute_stderr
  diff /dev/null <(ls -A "$tree/work")
}

@test "it answers a missing file as curl does for a 404" {
  setup_test "$tree"

  run -22 --separate-stderr in_dir "$tree/work" "${case_env[@]}" curl -fsSLO https://get.pulumi.com/releases/sdk/pulumi-v9.9.9-linux-x64.tar.gz

  refute_output
  assert_stderr 'curl: (22) The requested URL returned error: 404'
  diff /dev/null <(ls -A "$tree/work")
}

@test "it fails closed on another host" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree/work" "${case_env[@]}" curl -fsSL https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt

  refute_output
  assert_stderr 'unexpected: -fsSL https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt'
  diff - "$tree/calls" <<< '["curl","-fsSL","https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt"]'
}

@test "it fails closed on a path outside the release directory" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree/work" "${case_env[@]}" curl -fsSL https://get.pulumi.com/releases/sdk/../../calls

  refute_output
  assert_stderr 'unexpected: -fsSL https://get.pulumi.com/releases/sdk/../../calls'
}
