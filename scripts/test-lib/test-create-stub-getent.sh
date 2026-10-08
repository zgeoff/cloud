#!/usr/bin/env bash
# Test for create-stub-getent.sh: the getent stand-in prints a host it holds as glibc's
# getent prints a hosts entry, exits 2 with nothing for a name it does not hold or when it
# has no records, and fails closed on any other database.
#
#   bash scripts/test-lib/test-create-stub-getent.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-getent.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_prints_a_host_it_holds_as_getent_prints_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '10.0.0.1 other.example' '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    getent hosts atc.geoff.cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '104.21.32.1     atc.geoff.cloud'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["getent","hosts","atc.geoff.cloud"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_exits_2_with_nothing_for_a_name_it_does_not_hold() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '10.0.0.1 other.example' > "$tree/hosts"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    getent hosts atc.geoff.cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["getent","hosts","atc.geoff.cloud"]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_exits_2_with_nothing_when_it_holds_no_records() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    getent hosts atc.geoff.cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["getent","hosts","atc.geoff.cloud"]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_database() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    getent passwd root > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: passwd root'
  diff - "$tree/calls" <<< '["getent","passwd","root"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Pins the stand-in's not-found answer to the real getent's: a hosts lookup of a name that
# the files source cannot hold, asked of the files source alone, so no DNS is queried.
it_answers_a_name_it_does_not_hold_as_the_real_getent_does() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin getent -s files hosts stub-getent-test.invalid \
    > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    getent hosts stub-getent-test.invalid > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  [ "$status" = "$real_status" ] || { echo "exit $status, want $real_status" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, and the
# HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_getent "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
