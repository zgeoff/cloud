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

it_logs_a_call_and_fails_closed_with_exit_97() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" scp -o BatchMode=yes "$tree/calls" root@geoffcloud:/tmp/ \
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
tailscale
TOOLS
}

it_fails_closed_for_every_named_tool() {
  local tool statuses=""
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  for tool in rsync scp sftp tailscale; do
    env -i PATH="$tree/bin:/usr/bin:/bin" "$tool" status > /dev/null 2>&1 || statuses+="$tool $? "
  done

  diff - <(echo "$statuses") <<< 'rsync 97 scp 97 sftp 97 tailscale 97 '
}

# Runtime every case needs: the stand-ins for rsync, scp, sftp and tailscale in <tree>/bin.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" rsync scp sftp tailscale
}

run_cases
