#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for connect-k3s.sh: it reads the host's k3s kubeconfig, points its server
# at the host's tailnet name, stores it in 1Password as a new document or over the stored
# one, and adds the K3S_KUBECONFIG reference to .env once. It touches no host and no
# 1Password vault: ssh and op are stand-ins from scripts/src/test-utils/shell that log their argv as JSON lines,
# "the host" is a directory in the case's tree, and the vault is a directory beside it.
# Each case runs the script under `env -i` from its tree, with only the variables it sets,
# and compares its whole stdout, stderr and call log, the stored document and .env, and its
# exact exit code. A .env the script may not append to is real state: a read-only file, which
# binds a run as root too through run_with_file_modes.
#
#   bash scripts/run-bats.sh
#   CASE='.env' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-k3s-ssh.sh'
  load 'src/test-utils/shell/create-stub-kubeconfig-op.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  load 'src/test-utils/shell/run-with-file-modes.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the script in <tree>/scripts, beside the shared constants in
# <tree>/packages/topology, the ssh and op stand-ins with fail-closed
# stand-ins for the other remote tools in <tree>/bin, checked so no call can reach a real
# remote tool, the empty call log, the host's directory, and the HOME and TMPDIR the script
# runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/host" "$tree/scripts" "$tree/packages/topology"
  : > "$tree/calls"
  cp "$BATS_TEST_DIRNAME/connect-k3s.sh" "$tree/scripts/"
  # the script reads k3s's API port from the shared constants beside it
  cp "$BATS_TEST_DIRNAME/../packages/topology/constants.json" "$tree/packages/topology/"
  create_stub_k3s_ssh "$tree/bin"
  create_stub_kubeconfig_op "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it stores a new kubeconfig with the tailnet server and adds its reference to env" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' 'apiVersion: v1' 'clusters:' '- cluster:' '    server: https://127.0.0.1:6443' '  name: default' \
    > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  refute_stderr
  assert_output 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" << 'DOC'
apiVersion: v1
clusters:
- cluster:
    server: https://geoffcloud:6443
  name: default
DOC
  run -0 diff - "$tree/.env" << 'ENV'
ONIDEL_API_KEY=op://cloud/onidel/credential

# k3s API over the tailnet (#6)
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
ENV
}

@test "it replaces the stored kubeconfig and leaves an env that has its reference" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/k3s-kubeconfig"
  printf '%s\n' 'old: kubeconfig' > "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml"
  printf '%s\n' 'apiVersion: v1' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml' > "$tree/.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  refute_stderr
  assert_output 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","edit","k3s-kubeconfig","--vault","cloud","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" << 'DOC'
apiVersion: v1
    server: https://geoffcloud:6443
DOC
  run -0 diff - "$tree/.env" <<< 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml'
}

@test "it reads the named host and points the server at it" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml' > "$tree/.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud-2 bash scripts/connect-k3s.sh geoffcloud-2

  refute_stderr
  assert_output 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud-2","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< '    server: https://geoffcloud-2:6443'
}

@test "it writes env with its reference when none is there" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  assert_stderr 'grep: .env: No such file or directory'
  assert_output 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/.env" << 'ENV'

# k3s API over the tailnet (#6)
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
ENV
}

@test "it fails with ssh exit 255 and stores nothing when the host does not answer" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  run -255 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_SSH_UNREACHABLE=1 bash scripts/connect-k3s.sh

  refute_output
  assert_stderr $'ssh: connect to host geoffcloud port 22: Connection timed out\r'

  run -0 diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  ls -A "$tree/vault/cloud" > "$tree/items"
  run -0 diff /dev/null "$tree/items"
  run -0 diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
}

@test "it fails with exit 1 and stores nothing when the host has no k3s kubeconfig" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  refute_output
  assert_stderr 'cat: /etc/rancher/k3s/k3s.yaml: No such file or directory'

  run -0 diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  ls -A "$tree/vault/cloud" > "$tree/items"
  run -0 diff /dev/null "$tree/items"
  run -0 diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
}

@test "it fails with op exit 1 and leaves env when the new document is refused" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_OP_FAIL_AT=document-create bash scripts/connect-k3s.sh

  refute_output
  assert_stderr "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  ls -A "$tree/vault/cloud" > "$tree/items"
  run -0 diff /dev/null "$tree/items"
  run -0 diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
}

@test "it fails with op exit 1 and keeps the stored kubeconfig when the edit is refused" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/k3s-kubeconfig"
  printf '%s\n' 'old: kubeconfig' > "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_OP_FAIL_AT=document-edit bash scripts/connect-k3s.sh

  refute_output
  assert_stderr "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","edit","k3s-kubeconfig","--vault","cloud","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< 'old: kubeconfig'
  run -0 diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
}

@test "it fails with exit 1 after storing when it may not append to env" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"
  chmod 0444 "$tree/.env"

  run -1 --separate-stderr run_with_file_modes env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  refute_output
  assert_stderr 'scripts/connect-k3s.sh: line 23: .env: Permission denied'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< '    server: https://geoffcloud:6443'
  run -0 diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
}

@test "it completes env on a second run after a failed env write" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"
  chmod 0444 "$tree/.env"
  run -1 --separate-stderr run_with_file_modes env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh
  assert_stderr 'scripts/connect-k3s.sh: line 23: .env: Permission denied'
  chmod 0644 "$tree/.env"
  : > "$tree/calls"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash scripts/connect-k3s.sh

  refute_stderr
  assert_output 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'

  run -0 diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","edit","k3s-kubeconfig","--vault","cloud","--file-name","kubeconfig.yaml","-"]
CALLS
  run -0 diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< '    server: https://geoffcloud:6443'
  run -0 diff - "$tree/.env" << 'ENV'
ONIDEL_API_KEY=op://cloud/onidel/credential

# k3s API over the tailnet (#6)
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
ENV
}
