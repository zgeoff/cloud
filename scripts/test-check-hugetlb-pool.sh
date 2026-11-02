#!/usr/bin/env bash
# Test for check-hugetlb-pool.sh: it passes when the host reserved the whole hugetlb pool its system
# configures and when the system configures none, and fails naming both counts when the pool is
# short or a count is not a number. It stops with ssh's exit code when the host refuses the
# connection. ssh is the NixOS host stand-in from test-support/shell, which answers the pool query
# from the case's STUB_HUGETLB_RESERVED and STUB_HUGETLB_CONFIGURED, and hands the refused case to
# the real ssh on a dead loopback port. Each case runs the script under `env -i` and compares its
# stdout, stderr and ssh call log.
#
#   bash scripts/test-check-hugetlb-pool.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-nixos-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-hugetlb-pool.sh"
# the one remote command the check runs, as the call log records it
pool_call='["ssh","-o","BatchMode=yes","root@geoffcloud","sysctl -n vm.nr_hugepages; sed -n '"'"'s/^vm\\.nr_hugepages=//p'"'"' /etc/sysctl.d/60-nixos.conf"]'

# setup_test <tree>: the home and temp folders the cases run with, the ssh stand-in, fail-closed
# stand-ins for the other remote tools, and a guard that ends the case unless each resolves to a
# stand-in
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

it_passes_when_the_host_reserved_its_whole_pool() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=6144 STUB_HUGETLB_CONFIGURED=6144 \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "== root@geoffcloud reserved its whole hugetlb pool: 6144 pages"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$pool_call"
  assert_status 0 "$status"
}

it_passes_when_the_system_configures_no_pool() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "== root@geoffcloud configures no hugetlb pool"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$pool_call"
  assert_status 0 "$status"
}

it_fails_naming_both_counts_when_the_pool_is_short() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=4100 STUB_HUGETLB_CONFIGURED=6144 \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "root@geoffcloud reserved 4100 of its 6144 hugetlb pages, so impd refuses each boot and wake past them; reboot the host, which reserves the whole pool early in boot, then switch again"
  diff - "$tree/calls" <<< "$pool_call"
  assert_status 1 "$status"
}

it_fails_naming_both_counts_when_one_is_not_a_number() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=6144 STUB_HUGETLB_CONFIGURED='6144 # pool' \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "root@geoffcloud reports '6144' reserved and '6144 # pool' configured hugetlb pages, which are not both numbers"
  diff - "$tree/calls" <<< "$pool_call"
  assert_status 1 "$status"
}

it_stops_with_ssh_s_exit_code_when_the_host_refuses_the_connection() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 bash "$script" ssh://root@127.0.0.1:1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< "${pool_call/root@geoffcloud/ssh://root@127.0.0.1:1}"
  assert_status 255 "$status"
}

run_cases
