#!/usr/bin/env bash
# Test for create-stub-k3s-ssh.sh: the ssh stand-in answers the kubeconfig read with the
# case's host file, with cat's error when it is missing, with OpenSSH's timeout when the
# host does not answer, and fails closed on anything else. It never runs a command.
#
#   bash scripts/test-lib/test-create-stub-k3s-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-k3s-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_prints_the_hosts_k3s_kubeconfig() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
apiVersion: v1
    server: https://127.0.0.1:6443
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_cats_error_and_exit_1_when_the_host_has_no_kubeconfig() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'cat: /etc/rancher/k3s/k3s.yaml: No such file or directory'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The host's missing file and the real cat agree: the same message for the same path.
it_fails_a_missing_kubeconfig_as_the_real_cat_does() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin LC_ALL=C cat "$tree/host/k3s.yaml" > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/real-out" "$tree/out"
  sed "s|$tree/host/k3s.yaml|/etc/rancher/k3s/k3s.yaml|" "$tree/real-err" > "$tree/real-err-at-host-path"
  diff "$tree/real-err-at-host-path" "$tree/err"
  [ "$status" = "$real_status" ] || { echo "exit $status, want $real_status" >&2; exit 1; }
}

it_times_out_with_exit_255_when_the_host_does_not_answer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' > "$tree/host/k3s.yaml"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_SSH_UNREACHABLE=1 ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host geoffcloud port 22: Connection timed out\r'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' > "$tree/host/k3s.yaml"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@other cat /etc/rancher/k3s/k3s.yaml > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: root@other cat /etc/rancher/k3s/k3s.yaml'
  diff - "$tree/calls" <<< '["ssh","root@other","cat","/etc/rancher/k3s/k3s.yaml"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud "touch $tree/ran" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: root@geoffcloud touch $tree/ran"
  diff - "$tree/calls" <<< "[\"ssh\",\"root@geoffcloud\",\"touch $tree/ran\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for the
# other remote tools, checked so no call can reach a real remote tool, the empty call log,
# the host's directory, and the HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/host"
  : > "$tree/calls"
  create_stub_k3s_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
