#!/usr/bin/env bash
# Test for create-stub-release-curl.sh: the curl stand-in logs each call, prints a version's
# registry metadata, copies a tarball to the -o file, answers a missing file as curl 8.5.0 answers
# the registry's 404, and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-release-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-release-curl.sh"

# setup_test <tree>: the stand-in in <tree>/bin and the HOME and TMPDIR it runs with. It sets
# case_env, the environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_release_curl "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_prints_the_version_metadata_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/npm/auto-mode"
  echo '{"version":"0.20.0"}' > "$tree/npm/auto-mode/0.20.0.json"

  "${case_env[@]}" curl -fsSL https://registry.npmjs.org/auto-mode/0.20.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"version":"0.20.0"}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-fsSL","https://registry.npmjs.org/auto-mode/0.20.0"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_copies_the_tarball_to_the_output_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/npm/auto-mode"
  echo 'tarball bytes' > "$tree/npm/auto-mode/auto-mode-0.20.0.tgz"

  "${case_env[@]}" curl -fsSL -o "$tree/got.tgz" https://registry.npmjs.org/auto-mode/-/auto-mode-0.20.0.tgz > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/got.tgz" <<< 'tarball bytes'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"curl\",\"-fsSL\",\"-o\",\"$tree/got.tgz\",\"https://registry.npmjs.org/auto-mode/-/auto-mode-0.20.0.tgz\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_missing_metadata_as_curl_answers_a_404() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" curl -fsSL https://registry.npmjs.org/auto-mode/9.9.9 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  [ "$status" = 22 ] || {
    echo "exit $status, want 22" >&2
    exit 1
  }
}

it_answers_a_missing_tarball_as_curl_answers_a_404_with_no_output_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" curl -fsSL -o "$tree/got.tgz" https://registry.npmjs.org/auto-mode/-/auto-mode-9.9.9.tgz > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  [ ! -e "$tree/got.tgz" ] || {
    echo "the output file exists" >&2
    exit 1
  }
  [ "$status" = 22 ] || {
    echo "exit $status, want 22" >&2
    exit 1
  }
}

it_fails_closed_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" curl -fsSL https://example.invalid/ > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -fsSL https://example.invalid/'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

run_cases
