#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-k3s-ssh.sh: the ssh stand-in answers the kubeconfig read with the
# case's host file, with cat's error when it is missing, with OpenSSH's timeout when the
# host does not answer, and fails closed on anything else. It never runs a command.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-k3s-ssh.sh'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it prints the hosts k3s kubeconfig" {
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml

  assert_output - << 'OUT'
apiVersion: v1
    server: https://127.0.0.1:6443
OUT
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
}

@test "it fails with cats error and exit 1 when the host has no kubeconfig" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml

  refute_output
  assert_stderr 'cat: /etc/rancher/k3s/k3s.yaml: No such file or directory'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
}

# The host's missing file and the real cat agree: the same message for the same path.
@test "it fails a missing kubeconfig as the real cat does" {
  setup_test "$tree"
  run -1 --separate-stderr env -i PATH=/usr/bin:/bin LC_ALL=C cat "$tree/host/k3s.yaml"
  local real_output="$output" real_stderr="${stderr//"$tree/host/k3s.yaml"//etc/rancher/k3s/k3s.yaml}"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml

  assert_output "$real_output"
  assert_stderr "$real_stderr"
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
}

@test "it times out with exit 255 when the host does not answer" {
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' > "$tree/host/k3s.yaml"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_SSH_UNREACHABLE=1 ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml

  refute_output
  assert_stderr $'ssh: connect to host geoffcloud port 22: Connection timed out\r'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
}

@test "it fails closed with exit 97 on another host" {
  setup_test "$tree"
  printf '%s\n' 'apiVersion: v1' > "$tree/host/k3s.yaml"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@other cat /etc/rancher/k3s/k3s.yaml

  refute_output
  assert_stderr 'unexpected: root@other cat /etc/rancher/k3s/k3s.yaml'
  diff - "$tree/calls" <<< '["ssh","root@other","cat","/etc/rancher/k3s/k3s.yaml"]'
}

@test "it fails closed with exit 97 on another command" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud "touch $tree/ran"

  refute_output
  assert_stderr "unexpected: root@geoffcloud touch $tree/ran"
  diff - "$tree/calls" <<< "[\"ssh\",\"root@geoffcloud\",\"touch $tree/ran\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}
