#!/usr/bin/env bash
# Test for print-op-error.sh: print_op_error prints each of op's error lines on stderr and exits
# 1, and fails closed with exit 97 on an error it does not know or a wrong argument count. Each
# case runs it in a child bash, because it exits.
#
#   bash test-support/shell/test-print-op-error.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"

helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/print-op-error.sh"

it_prints_ops_missing_vault_line_and_exits_1() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error missing-vault cloud; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 "cloud" isn'\''t a vault in this account. Specify the vault with its ID or name.'
  assert_status 1 "$status"
}

it_prints_ops_missing_item_line_and_exits_1() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error missing-item kubeconfig cloud; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 "kubeconfig" isn'\''t an item in the "cloud" vault. Specify the item with its UUID, name, or domain.'
  assert_status 1 "$status"
}

it_prints_ops_unreadable_secret_line_and_exits_1() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error unreadable-secret op://cloud/dns-token/credential cloud dns-token; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/dns-token/credential: could not get item cloud/dns-token: "dns-token" isn'\''t an item in the "cloud" vault.'
  assert_status 1 "$status"
}

it_prints_ops_rate_limit_line_and_exits_1() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error rate-limit; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You'\''ve reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests.'
  assert_status 1 "$status"
}

it_fails_closed_with_exit_97_on_an_unknown_error() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error missing-field x; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: print_op_error missing-field x'
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_on_a_wrong_argument_count() {
  local status=0
  create_case_tree

  # shellcheck disable=SC2016 # the child bash expands its own script
  bash -c 'source "$1"; print_op_error missing-vault; echo after' _ "$helper" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: print_op_error missing-vault'
  assert_status 97 "$status"
}

run_cases
