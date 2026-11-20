#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-hugetlb-pool.sh: it passes when the host reserved the whole hugetlb pool its system
# configures and when the system configures none, and fails naming both counts when the pool is
# short or a count is not a number. It stops with ssh's exit code when the host refuses the
# connection. ssh is the NixOS host stand-in from scripts/src/test-utils/shell, which answers the pool query
# from the case's STUB_HUGETLB_RESERVED and STUB_HUGETLB_CONFIGURED, and hands the refused case to
# the real ssh on a dead loopback port. Each case runs the script under `env -i` and compares its
# stdout, stderr and ssh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-nixos-ssh.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-hugetlb-pool.sh"
  # the one remote command the check runs, as the call log records it
  pool_call='["ssh","-o","BatchMode=yes","root@geoffcloud","sysctl -n vm.nr_hugepages; sed -n '"'"'s/^vm\\.nr_hugepages=//p'"'"' /etc/sysctl.d/60-nixos.conf"]'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

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

@test "it passes when the host reserved its whole pool" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=6144 STUB_HUGETLB_CONFIGURED=6144 \
    bash "$script" root@geoffcloud

  assert_output "== root@geoffcloud reserved its whole hugetlb pool: 6144 pages"
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$pool_call"
}

@test "it passes when the system configures no pool" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script" root@geoffcloud

  assert_output "== root@geoffcloud configures no hugetlb pool"
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$pool_call"
}

@test "it fails naming both counts when the pool is short" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=4100 STUB_HUGETLB_CONFIGURED=6144 \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr "root@geoffcloud reserved 4100 of its 6144 hugetlb pages, so impd refuses each boot and wake past them; reboot the host, which reserves the whole pool early in boot, then switch again"

  run -0 diff - "$tree/calls" <<< "$pool_call"
}

@test "it fails naming both counts when one is not a number" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=6144 STUB_HUGETLB_CONFIGURED='6144 # pool' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr "root@geoffcloud reports '6144' reserved and '6144 # pool' configured hugetlb pages, which are not both numbers"

  run -0 diff - "$tree/calls" <<< "$pool_call"
}

@test "it stops with ssh s exit code when the host refuses the connection" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 bash "$script" ssh://root@127.0.0.1:1

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'

  run -0 diff - "$tree/calls" <<< "${pool_call/root@geoffcloud/ssh://root@127.0.0.1:1}"
}
