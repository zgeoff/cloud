#!/usr/bin/env bash
# Hermetic test for connect-k3s.sh: it reads the host's k3s kubeconfig, points its server
# at the host's tailnet name, stores it in 1Password as a new document or over the stored
# one, and adds the K3S_KUBECONFIG reference to .env once. It touches no host and no
# 1Password vault: ssh and op are stand-ins from test-lib that log their argv as JSON lines,
# "the host" is a directory in the case's tree, and the vault is a directory beside it.
# Each case runs the script under `env -i` from its tree, with only the variables it sets,
# and compares its whole stdout, stderr and call log, the stored document and .env, and its
# exact exit code. A .env the script may not append to is real state: a read-only file.
#
#   bash scripts/test-connect-k3s.sh
#   CASE='.env' bash scripts/test-connect-k3s.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-k3s-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-kubeconfig-op.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_stores_a_new_kubeconfig_with_the_tailnet_server_and_adds_its_reference_to_env() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' 'apiVersion: v1' 'clusters:' '- cluster:' '    server: https://127.0.0.1:6443' '  name: default' \
    > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" << 'DOC'
apiVersion: v1
clusters:
- cluster:
    server: https://geoffcloud:6443
  name: default
DOC
  diff - "$tree/.env" << 'ENV'
ONIDEL_API_KEY=op://cloud/onidel/credential

# k3s API over the tailnet (#6)
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
ENV
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_replaces_the_stored_kubeconfig_and_leaves_an_env_that_has_its_reference() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/k3s-kubeconfig"
  printf '%s\n' 'old: kubeconfig' > "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml"
  printf '%s\n' 'apiVersion: v1' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","edit","k3s-kubeconfig","--vault","cloud","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" << 'DOC'
apiVersion: v1
    server: https://geoffcloud:6443
DOC
  diff - "$tree/.env" <<< 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_reads_the_named_host_and_points_the_server_at_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud-2 bash connect-k3s.sh geoffcloud-2) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud-2","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< '    server: https://geoffcloud-2:6443'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_writes_env_with_its_reference_when_none_is_there() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'grep: .env: No such file or directory'
  diff - "$tree/out" <<< 'stored op://cloud/k3s-kubeconfig/kubeconfig.yaml; run: bun run up -- --yes'
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/.env" << 'ENV'

# k3s API over the tailnet (#6)
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
ENV
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_ssh_exit_255_and_stores_nothing_when_the_host_does_not_answer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_SSH_UNREACHABLE=1 bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host geoffcloud port 22: Connection timed out\r'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_fails_with_exit_1_and_stores_nothing_when_the_host_has_no_k3s_kubeconfig() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'cat: /etc/rancher/k3s/k3s.yaml: No such file or directory'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]'
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_op_exit_1_and_leaves_env_when_the_new_document_is_refused() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_OP_FAIL_AT=document-create bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_op_exit_1_and_keeps_the_stored_kubeconfig_when_the_edit_is_refused() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/k3s-kubeconfig"
  printf '%s\n' 'old: kubeconfig' > "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_OP_FAIL_AT=document-edit bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","edit","k3s-kubeconfig","--vault","cloud","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< 'old: kubeconfig'
  diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_exit_1_after_storing_when_it_may_not_append_to_env() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' '    server: https://127.0.0.1:6443' > "$tree/host/k3s.yaml"
  printf '%s\n' 'ONIDEL_API_KEY=op://cloud/onidel/credential' > "$tree/.env"
  chmod 0444 "$tree/.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash connect-k3s.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'connect-k3s.sh: line 18: .env: Permission denied'
  diff - "$tree/calls" << 'CALLS'
["ssh","root@geoffcloud","cat","/etc/rancher/k3s/k3s.yaml"]
["op","item","get","k3s-kubeconfig","--vault","cloud"]
["op","document","create","--vault","cloud","--title","k3s-kubeconfig","--file-name","kubeconfig.yaml","-"]
CALLS
  diff - "$tree/vault/cloud/k3s-kubeconfig/kubeconfig.yaml" <<< '    server: https://geoffcloud:6443'
  diff - "$tree/.env" <<< 'ONIDEL_API_KEY=op://cloud/onidel/credential'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>, the ssh and op stand-ins with fail-closed
# stand-ins for the other remote tools in <tree>/bin, checked so no call can reach a real
# remote tool, the empty call log, the host's directory, and the HOME and TMPDIR the script
# runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/host"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/connect-k3s.sh" "$tree/"
  create_stub_k3s_ssh "$tree/bin"
  create_stub_kubeconfig_op "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
