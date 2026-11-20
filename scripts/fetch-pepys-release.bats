#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for fetch-pepys-release.sh: in a copy of the script with the case's own pins, it installs
# the host binary as <dir>/pepys-host, mode 0555, when the release's SHA256SUMS and the pin both
# match it, and stops with no binary in <dir> when either differs. gh is a stand-in that answers
# the download from the case's files, so no case reaches GitHub.
#
#   bash scripts/run-bats.sh
#   CASE='pin' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  scripts="$BATS_TEST_DIRNAME"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

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

@test "it installs the host binary read only and executable when both checks match" {
  local hash
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" "$hash"

  run -0 --separate-stderr run_fetch "$tree" "$tree/context"

  refute_stderr

  run -0 cmp <(printf 'host binary for tests\n') "$tree/context/pepys-host"
  [ "$(stat -c %a "$tree/context/pepys-host")" = 555 ]
  run -0 diff - <(cd "$tree/context" && find . | sort) << 'EOF2'
.
./pepys-host
EOF2
}

@test "it stops with no binary when the release sums differ" {
  local hash
  hash="$(asset_hash)"
  setup_test "$tree" 1111111111111111111111111111111111111111111111111111111111111111 "$hash"

  run ! --separate-stderr run_fetch "$tree" "$tree/context"

  assert_output --partial FAILED
  refute [ -e "$tree/context/pepys-host" ]
}

@test "it stops with no binary when the pin differs" {
  local hash
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" 2222222222222222222222222222222222222222222222222222222222222222

  run ! --separate-stderr run_fetch "$tree" "$tree/context"

  assert_output --partial FAILED
  refute [ -e "$tree/context/pepys-host" ]
}

@test "it refuses to run without a context folder" {
  local hash
  hash="$(asset_hash)"
  setup_test "$tree" "$hash" "$hash"

  run ! --separate-stderr run_fetch "$tree"

  assert_stderr --partial 'usage: fetch-pepys-release.sh <context-dir>'
  refute [ -e "$tree/calls" ]
}
