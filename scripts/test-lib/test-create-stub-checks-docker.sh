#!/usr/bin/env bash
# Test for create-stub-checks-docker.sh: the docker stand-in answers the nix eval and build that
# test-nixos.sh runs, copies what the build mounts at /src, logs every call, and fails closed on
# any other call. No nix runs here; the stand-in's exit 1 for a failed eval or build is the
# one its header records from a one-off check against nix 2.35.2.
#
#   bash scripts/test-lib/test-create-stub-checks-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-checks-docker.sh"

it_prints_the_check_names_without_a_trailing_newline_for_an_eval() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=$'atc-daemon\nimpd-restore\n' \
    docker run --rm nixos/nix nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames \
    > "$tree/out" 2> "$tree/err" || status=$?

  printf 'atc-daemon\nimpd-restore\n' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","run","--rm","nixos/nix","nix","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","builtins.attrNames"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_an_eval_with_the_set_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=atc-daemon \
    STUB_EVAL_ERROR="error: undefined variable 'x'" \
    docker run --rm nixos/nix nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: undefined variable 'x'"
  diff - "$tree/calls" <<< '["docker","run","--rm","nixos/nix","nix","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","builtins.attrNames"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_copies_the_directory_mounted_at_src_for_a_build() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    docker run --rm -v "$tree/src:/src:ro" nixos/nix nix build --no-link -L 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/src" "$tree/saw"
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"nixos/nix\",\"nix\",\"build\",\"--no-link\",\"-L\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_copies_the_source_then_fails_a_build_with_the_set_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_ERROR="error: Cannot build 'x.drv'." \
    docker run --rm -v "$tree/src:/src:ro" nixos/nix nix build --no-link -L 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/src" "$tree/saw"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: Cannot build 'x.drv'."
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"nixos/nix\",\"nix\",\"build\",\"--no-link\",\"-L\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" docker volume rm cloud-nixos-checks-store \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: volume rm cloud-nixos-checks-store"
  diff - "$tree/calls" <<< '["docker","volume","rm","cloud-nixos-checks-store"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each call
# runs with. The empty call log is boot data: the stand-in appends to it, and a case
# compares it whole.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_checks_docker "$tree/bin"
}

run_cases
