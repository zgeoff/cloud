#!/usr/bin/env bash
# Test for create-stub-release-download-gh.sh: the gh stand-in logs each call, copies each named
# asset of a release the test wrote into the download directory, answers a release the tree lacks
# as the real gh does, and fails closed on an asset the release lacks and on any other call.
#
#   bash scripts/test-lib/test-create-stub-release-download-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-release-download-gh.sh"

# setup_test <tree>: the stand-in in <tree>/bin, the HOME and TMPDIR it runs with and an empty
# download directory, <tree>/out-dir. It sets case_env, the environment every call runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/out-dir"
  create_stub_release_download_gh "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_copies_each_named_asset_of_the_release_into_the_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0"
  echo binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"
  echo sums > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/SHA256SUMS"
  echo other > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-linux-arm64"

  "${case_env[@]}" gh release download @zgeoff/atc@2.27.0 -R zgeoff/atc -p atc-gateway-linux-x64 -p SHA256SUMS -D "$tree/out-dir" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(find "$tree/out-dir" -mindepth 1 -printf '%f\n' | LC_ALL=C sort) << 'EOF'
SHA256SUMS
atc-gateway-linux-x64
EOF
  diff - "$tree/out-dir/atc-gateway-linux-x64" <<< binary
  diff - "$tree/out-dir/SHA256SUMS" <<< sums
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"@zgeoff/atc@2.27.0\",\"-R\",\"zgeoff/atc\",\"-p\",\"atc-gateway-linux-x64\",\"-p\",\"SHA256SUMS\",\"-D\",\"$tree/out-dir\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_missing_release_as_gh_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh release download @zgeoff/atc@9.9.9 -R zgeoff/atc -p atc-gateway-linux-x64 -D "$tree/out-dir" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  diff /dev/null <(ls -A "$tree/out-dir")
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_closed_on_an_asset_the_release_lacks_and_copies_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0"
  echo binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"

  "${case_env[@]}" gh release download @zgeoff/atc@2.27.0 -R zgeoff/atc -p atc-gateway-linux-x64 -p SHA256SUMS -D "$tree/out-dir" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: release download @zgeoff/atc@2.27.0 -R zgeoff/atc -p atc-gateway-linux-x64 -p SHA256SUMS -D $tree/out-dir"
  diff /dev/null <(ls -A "$tree/out-dir")
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh release view @zgeoff/atc@2.27.0 -R zgeoff/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: release view @zgeoff/atc@2.27.0 -R zgeoff/atc'
  diff - "$tree/calls" <<< '["gh","release","view","@zgeoff/atc@2.27.0","-R","zgeoff/atc"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

run_cases
