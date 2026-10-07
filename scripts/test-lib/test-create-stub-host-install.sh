#!/usr/bin/env bash
# Test for create-stub-host-install.sh: the host install stand-in runs the real
# `install -d -m 0700` for the credentials script's call, without the owner, so its
# result and its errors are coreutils' own, and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-host-install.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-host-install.sh"

it_creates_the_directory_with_mode_0700() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    install -d -m 0700 -o root -g root "$tree/host/secrets" > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(stat -c %a "$tree/host/secrets") <<< 700
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"install\",\"-d\",\"-m\",\"0700\",\"-o\",\"root\",\"-g\",\"root\",\"$tree/host/secrets\"]"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_sets_mode_0700_on_a_directory_that_exists() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -m 0755 "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    install -d -m 0700 -o root -g root "$tree/host/secrets" > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(stat -c %a "$tree/host/secrets") <<< 700
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_installs_own_error_under_a_parent_it_may_not_write() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  chmod 0500 "$tree/host"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    install -d -m 0700 -o root -g root "$tree/host/secrets" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "install: cannot create directory '$tree/host/secrets': Permission denied"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    install -m 0600 "$tree/calls" "$tree/host/copy" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "unexpected: -m 0600 $tree/calls $tree/host/copy"
  [ ! -e "$tree/host/copy" ] || { echo "the unknown call ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the host's root.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/host"
  create_stub_host_install "$tree/bin"
}

run_cases
