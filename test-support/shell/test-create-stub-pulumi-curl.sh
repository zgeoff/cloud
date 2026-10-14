#!/usr/bin/env bash
# Test for create-stub-pulumi-curl.sh: the curl stand-in logs each call, writes a release file
# into the working directory for -O and prints one otherwise, answers a file the tree lacks as
# curl does for a 404 with -f, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-pulumi-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-pulumi-curl.sh"

# setup_test <tree>: the stand-in in <tree>/bin, the HOME and TMPDIR it runs with, an empty
# working directory <tree>/work and an empty release directory. It sets case_env, the
# environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work" "$tree/pulumi"
  create_stub_pulumi_curl "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_writes_the_release_file_into_the_working_directory_for_a_named_download() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo tarball > "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz"

  (cd "$tree/work" && "${case_env[@]}" curl -fsSLO https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/work/pulumi-v1.2.3-linux-x64.tar.gz" <<< tarball
  diff - "$tree/calls" <<< '["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_the_release_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'abc  pulumi-v1.2.3-linux-x64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  (cd "$tree/work" && "${case_env[@]}" curl -fsSL https://get.pulumi.com/releases/sdk/pulumi-1.2.3-checksums.txt) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'abc  pulumi-v1.2.3-linux-x64.tar.gz'
  diff /dev/null "$tree/err"
  diff /dev/null <(ls -A "$tree/work")
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_missing_file_as_curl_does_for_a_404() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/work" && "${case_env[@]}" curl -fsSLO https://get.pulumi.com/releases/sdk/pulumi-v9.9.9-linux-x64.tar.gz) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  diff /dev/null <(ls -A "$tree/work")
  [ "$status" = 22 ] || {
    echo "exit $status, want 22" >&2
    exit 1
  }
}

it_fails_closed_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/work" && "${case_env[@]}" curl -fsSL https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -fsSL https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt'
  diff - "$tree/calls" <<< '["curl","-fsSL","https://example.invalid/releases/sdk/pulumi-1.2.3-checksums.txt"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_on_a_path_outside_the_release_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/work" && "${case_env[@]}" curl -fsSL https://get.pulumi.com/releases/sdk/../../calls) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -fsSL https://get.pulumi.com/releases/sdk/../../calls'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

run_cases
