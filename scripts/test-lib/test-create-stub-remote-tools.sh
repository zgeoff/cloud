#!/usr/bin/env bash
# Test for create-stub-remote-tools.sh: each remote-tool stand-in logs its call and fails
# closed with exit 97, and runs nothing else.
#
#   bash scripts/test-lib/test-create-stub-remote-tools.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_logs_a_call_and_fails_closed_with_exit_97() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" scp -o BatchMode=yes "$tree/calls" root@geoffcloud:/tmp/ \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: scp -o BatchMode=yes $tree/calls root@geoffcloud:/tmp/"
  diff - "$tree/calls" <<< "[\"scp\",\"-o\",\"BatchMode=yes\",\"$tree/calls\",\"root@geoffcloud:/tmp/\"]"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_writes_one_stand_in_for_each_named_tool() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
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

it_fails_closed_with_exit_97_for_rsync() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" rsync status \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: rsync status'
  diff - "$tree/calls" <<< '["rsync","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_for_scp() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" scp status \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: scp status'
  diff - "$tree/calls" <<< '["scp","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_for_sftp() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" sftp status \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: sftp status'
  diff - "$tree/calls" <<< '["sftp","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_for_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" ssh status \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: ssh status'
  diff - "$tree/calls" <<< '["ssh","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_for_tailscale() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" tailscale status \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: tailscale status'
  diff - "$tree/calls" <<< '["tailscale","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
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

run_cases
