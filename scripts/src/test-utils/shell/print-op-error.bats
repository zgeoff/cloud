#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for print-op-error.sh: print_op_error prints each of op's error lines on stderr and exits
# 1, and fails closed with exit 97 on an error it does not know or a wrong argument count. Each
# case runs it in a child bash, because it exits.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  helper="$BATS_TEST_DIRNAME/print-op-error.sh"
}

teardown() {
  stop_timeout_watchdog
}

@test "it prints ops missing vault line and exits 1" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -1 --separate-stderr bash -c 'source "$1"; print_op_error missing-vault cloud; echo after' _ "$helper"

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 "cloud" isn'\''t a vault in this account. Specify the vault with its ID or name.'
}

@test "it prints ops missing item line and exits 1" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -1 --separate-stderr bash -c 'source "$1"; print_op_error missing-item kubeconfig cloud; echo after' _ "$helper"

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 "kubeconfig" isn'\''t an item in the "cloud" vault. Specify the item with its UUID, name, or domain.'
}

@test "it prints ops unreadable secret line and exits 1" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -1 --separate-stderr bash -c 'source "$1"; print_op_error unreadable-secret op://cloud/dns-token/credential cloud dns-token; echo after' _ "$helper"

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/dns-token/credential: could not get item cloud/dns-token: "dns-token" isn'\''t an item in the "cloud" vault.'
}

@test "it prints ops rate limit line and exits 1" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -1 --separate-stderr bash -c 'source "$1"; print_op_error rate-limit; echo after' _ "$helper"

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You'\''ve reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests.'
}

@test "it fails closed with exit 97 on an unknown error" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -97 --separate-stderr bash -c 'source "$1"; print_op_error missing-field x; echo after' _ "$helper"

  refute_output
  assert_stderr 'unexpected: print_op_error missing-field x'
}

@test "it fails closed with exit 97 on a wrong argument count" {
  # shellcheck disable=SC2016 # the child bash expands its own script
  run -97 --separate-stderr bash -c 'source "$1"; print_op_error missing-vault; echo after' _ "$helper"

  refute_output
  assert_stderr 'unexpected: print_op_error missing-vault'
}
