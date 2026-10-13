#!/usr/bin/env bash
# Test for create-stub-release-docker.sh: the docker stand-in logs each call, prints the manifest
# descriptor a test wrote for an image, answers a missing image as buildx 0.37.1 does, writes the
# test's lock into the directory a `nix flake lock` run mounts or fails it with STUB_LOCK_ERROR,
# and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-release-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-release-docker.sh"

# setup_test <tree>: the stand-in in <tree>/bin and the HOME and TMPDIR it runs with. It sets
# case_env, the environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_release_docker "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_prints_the_manifest_descriptor_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/images"
  echo '{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}' > "$tree/images/ghcr.io_zgeoff_imp-host:1.0.1.json"

  "${case_env[@]}" docker buildx imagetools inspect ghcr.io/zgeoff/imp-host:1.0.1 --format '{{json .Manifest}}' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","buildx","imagetools","inspect","ghcr.io/zgeoff/imp-host:1.0.1","--format","{{json .Manifest}}"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_a_missing_image_as_buildx_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" docker buildx imagetools inspect ghcr.io/zgeoff/imp-host:9.9.9 --format '{{json .Manifest}}' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'ERROR: ghcr.io/zgeoff/imp-host:9.9.9: not found'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_writes_the_test_lock_into_the_mounted_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/nixos"
  echo '{"old":true}' > "$tree/nixos/flake.lock"
  echo '{"new":true}' > "$tree/flake.lock"

  "${case_env[@]}" docker run --rm -v "$tree/nixos:/src" -w /src example.invalid/nix:1 sh -c \
    "nix --extra-experimental-features 'nix-command flakes' flake lock && chown 0:0 flake.lock" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/nixos/flake.lock" <<< '{"new":true}'
  diff - <(sed "s|$tree|TREE|g" "$tree/calls") << 'EOF'
["docker","run","--rm","-v","TREE/nixos:/src","-w","/src","example.invalid/nix:1","sh","-c","nix --extra-experimental-features 'nix-command flakes' flake lock && chown 0:0 flake.lock"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_lock_with_the_tests_error_and_leaves_the_lock_unchanged() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/nixos"
  echo '{"old":true}' > "$tree/nixos/flake.lock"
  echo '{"new":true}' > "$tree/flake.lock"

  "${case_env[@]}" STUB_LOCK_ERROR='error: no commit found' docker run --rm -v "$tree/nixos:/src" -w /src example.invalid/nix:1 sh -c \
    "nix --extra-experimental-features 'nix-command flakes' flake lock" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'error: no commit found'
  diff - "$tree/nixos/flake.lock" <<< '{"old":true}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_on_an_unexpected_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" docker run --rm alpine true > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run --rm alpine true'
  diff - "$tree/calls" <<< '["docker","run","--rm","alpine","true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

run_cases
