#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-remote-tools.sh: each remote-tool stand-in logs its call and fails
# closed with exit 97, and runs nothing else.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-ins for rsync, scp, sftp, ssh and tailscale in <tree>/bin,
# checked before any case runs a tool, so no call can reach a real remote tool, and the HOME and
# TMPDIR they run with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_remote_tools "$tree/bin" "$tree/calls" rsync scp sftp ssh tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it logs a call and fails closed with exit 97" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" scp -o BatchMode=yes "$tree/calls" root@geoffcloud:/tmp/

  refute_output
  assert_stderr "unexpected: scp -o BatchMode=yes $tree/calls root@geoffcloud:/tmp/"
  diff - "$tree/calls" <<< "[\"scp\",\"-o\",\"BatchMode=yes\",\"$tree/calls\",\"root@geoffcloud:/tmp/\"]"
}

@test "it writes one stand in for each named tool" {
  setup_test "$tree"

  find "$tree/bin" -type f -perm -u+x -printf '%P\n' | sort > "$tree/tools"

  diff - "$tree/tools" << 'TOOLS'
rsync
scp
sftp
ssh
tailscale
TOOLS
}

@test "it fails closed with exit 97 for rsync" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" rsync status

  refute_output
  assert_stderr 'unexpected: rsync status'
  diff - "$tree/calls" <<< '["rsync","status"]'
}

@test "it fails closed with exit 97 for scp" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" scp status

  refute_output
  assert_stderr 'unexpected: scp status'
  diff - "$tree/calls" <<< '["scp","status"]'
}

@test "it fails closed with exit 97 for sftp" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" sftp status

  refute_output
  assert_stderr 'unexpected: sftp status'
  diff - "$tree/calls" <<< '["sftp","status"]'
}

@test "it fails closed with exit 97 for ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" ssh status

  refute_output
  assert_stderr 'unexpected: ssh status'
  diff - "$tree/calls" <<< '["ssh","status"]'
}

@test "it fails closed with exit 97 for tailscale" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" tailscale status

  refute_output
  assert_stderr 'unexpected: tailscale status'
  diff - "$tree/calls" <<< '["tailscale","status"]'
}
