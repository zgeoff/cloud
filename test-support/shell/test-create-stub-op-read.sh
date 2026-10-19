#!/usr/bin/env bash
# Test for create-stub-op-read.sh: the op stand-in prints a field from the case's vault
# directory with no newline, fails a missing item with op's error and exit 1, and fails
# closed on anything else.
#
#   bash test-support/shell/test-create-stub-op-read.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-op-read.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_prints_the_field_with_no_newline() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"
  printf '%s' token-value > "$tree/vault/cloud/dns/credential"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' token-value | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
  assert_status 0 "$status"
}

it_fails_a_missing_item_with_ops_error_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/dns/credential: could not get item cloud/dns: "dns" isn't an item in the "cloud" vault.
ERR
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
  assert_status 1 "$status"
}

it_fails_closed_with_exit_97_on_a_field_the_item_does_not_hold() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: read --no-newline op://cloud/dns/credential'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_on_a_read_without_no_newline() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"
  printf '%s' token-value > "$tree/vault/cloud/dns/credential"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/dns/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: read op://cloud/dns/credential'
  diff - "$tree/calls" <<< '["op","read","op://cloud/dns/credential"]'
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_on_any_other_command() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: item list --vault cloud'
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud"]'
  assert_status 97 "$status"
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, and the
# HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_op_read "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
