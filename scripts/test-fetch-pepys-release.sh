#!/usr/bin/env bash
# Test for fetch-pepys-release.sh: in a copy of the script with the case's own pins, it installs
# the host binary as <dir>/pepys-host, mode 0555, when the release's SHA256SUMS and the pin both
# match it, and stops with no binary in <dir> when either differs. gh is a stand-in that answers
# the download from the case's files, so no case reaches GitHub.
#
#   bash scripts/test-fetch-pepys-release.sh
#   CASE='pin' bash scripts/test-fetch-pepys-release.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# setup_test <tree> <SHA256SUMS hash> <pinned hash>: a repo copy with the case's pins, and a gh
# stand-in whose download of v0.4.0 gives the asset and a SHA256SUMS with the given hash
setup_test() {
  local tree="$1" sums_hash="$2" pin_hash="$3"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/release" "$tree/repo/scripts" "$tree/repo/images/pepys"
  cp "$scripts/fetch-pepys-release.sh" "$tree/repo/scripts/"
  printf 'host binary for tests\n' > "$tree/release/pepys-host-linux-x64"
  echo "$sums_hash  pepys-host-linux-x64" > "$tree/release/SHA256SUMS"
  cat > "$tree/repo/images/pepys/versions.env" << EOF2
PEPYS_RELEASE=v0.4.0
PEPYS_HOST_ASSET=pepys-host-linux-x64
PEPYS_HOST_ASSET_SHA256=$pin_hash
EOF2
  jq -cn --arg asset "$tree/release/pepys-host-linux-x64" --arg sums "$tree/release/SHA256SUMS" \
    '{argv: ["gh", "release", "download", "v0.4.0", "-R", "zgeoff/pepys", "-p", "pepys-host-linux-x64", "-p", "SHA256SUMS", "-D", null],
      downloads: {"pepys-host-linux-x64": $asset, SHA256SUMS: $sums}}' > "$tree/responses"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/responses"
}

run_fetch() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$tree/repo/scripts/fetch-pepys-release.sh" "$@"
}

asset_hash() {
  printf 'host binary for tests\n' | sha256sum | cut -d' ' -f1
}

it_installs_the_host_binary_read_only_and_executable_when_both_checks_match() {
  local status=0 hash
  create_case_tree
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" "$hash"

  run_fetch "$tree" "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 0 "$status"
  diff /dev/null "$tree/err"
  printf 'host binary for tests\n' | cmp - "$tree/context/pepys-host"
  [ "$(stat -c %a "$tree/context/pepys-host")" = 555 ]
  diff - <(cd "$tree/context" && find . | sort) << 'EOF2'
.
./pepys-host
EOF2
}

it_stops_with_no_binary_when_the_release_sums_differ() {
  local status=0 hash
  create_case_tree
  hash="$(asset_hash)"
  setup_test "$tree" 1111111111111111111111111111111111111111111111111111111111111111 "$hash"

  run_fetch "$tree" "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  [ "$status" != 0 ]
  grep -q 'FAILED' "$tree/out"
  [ ! -e "$tree/context/pepys-host" ]
}

it_stops_with_no_binary_when_the_pin_differs() {
  local status=0 hash
  create_case_tree
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" 2222222222222222222222222222222222222222222222222222222222222222

  run_fetch "$tree" "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  [ "$status" != 0 ]
  grep -q 'FAILED' "$tree/out"
  [ ! -e "$tree/context/pepys-host" ]
}

it_refuses_to_run_without_a_context_folder() {
  local status=0 hash
  create_case_tree
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" "$hash"

  run_fetch "$tree" > "$tree/out" 2> "$tree/err" || status=$?

  [ "$status" != 0 ]
  grep -q 'usage: fetch-pepys-release.sh <context-dir>' "$tree/err"
  [ ! -e "$tree/calls" ]
}

run_cases
