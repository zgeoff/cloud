#!/usr/bin/env bash
# Test for create-stub-atc-key.sh: the atc-key stand-in prints the z.ai key it is given
# and fails closed on any other call. No atc-key runs here; it prints a key and a newline
# for a known provider, which the case pins as a literal.
#
#   bash scripts/test-lib/test-create-stub-atc-key.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-atc-key.sh"

it_prints_the_named_z_ai_key_and_logs_the_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ZAI_KEY=fixture-zai-key atc-key zai \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< fixture-zai-key
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["atc-key","zai"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_an_empty_line_for_an_empty_key() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ZAI_KEY= atc-key zai \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< ''
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["atc-key","zai"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_provider() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ZAI_KEY=fixture-zai-key atc-key openai \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: openai'
  diff - "$tree/calls" <<< '["atc-key","openai"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each call
# runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_atc_key "$tree/bin"
}

run_cases
