#!/usr/bin/env bash
# Test for create-stub-readiness-ssh.sh: the ssh stand-in answers the readiness checks'
# kubectl, free and systemctl calls from the case's cluster files and variables, answers a
# missing object with kubectl's NotFound error and exit 1, times every call out with exit
# 255 when the host does not answer, and fails closed on anything else. It runs nothing.
#
#   bash scripts/test-lib/test-create-stub-readiness-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-readiness-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_prints_the_named_node_line() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready   control-plane   1d   v1' \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get nodes --no-headers > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'geoffcloud   Ready   control-plane   1d   v1'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_a_namespace_it_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace"
  touch "$tree/cluster/namespace/atc"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get namespace atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
NAME   STATUS   AGE
atc    Active   2d
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_missing_namespace_with_kubectls_NotFound_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get namespace atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): namespaces "atc" not found'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_a_storage_class_it_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/storageclass"
  touch "$tree/cluster/storageclass/local-path-retain"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get storageclass local-path-retain > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path-retain   rancher.io/local-path   Retain          WaitForFirstConsumer   false                  2d
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_missing_storage_class_with_kubectls_NotFound_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get storageclass local-path-retain > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): storageclasses.storage.k8s.io "local-path-retain" not found'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_a_deployment_it_holds_with_the_namespace_before_or_after_get() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/deploy/atc"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl -n atc get deploy atc-gateway > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
atc-gateway   1/1     1            1           2d
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_missing_deployment_with_kubectls_NotFound_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl get -n atc deploy atc-gateway > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): deployments.apps "atc-gateway" not found'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_a_deployments_ready_replicas_with_no_newline() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/deploy/ingress"
  printf 2 > "$tree/cluster/deploy/ingress/cloudflared"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl -n ingress get deploy cloudflared -o 'jsonpath={.status.readyReplicas}' > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '2' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_ready_replicas_of_a_missing_deployment_with_kubectls_NotFound_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl -n ingress get deploy cloudflared -o 'jsonpath={.status.readyReplicas}' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): deployments.apps "cloudflared" not found'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_the_named_status_for_the_in_cluster_probe() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_PROBE_CODE=403 \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl -n atc run readiness-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.16.0 -- curl -s -o /dev/null -w '%{http_code}' -H 'Host: atc.geoff.cloud' http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '403' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_the_named_available_memory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_MEM_AVAILABLE=2048 \
    ssh -o BatchMode=yes root@geoffcloud "free -m | awk '/^Mem:/ {print \$7}'" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '2048'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_an_active_daemon_with_exit_0() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_DAEMON=active \
    ssh -o BatchMode=yes root@geoffcloud systemctl is-active --quiet atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_an_inactive_daemon_with_systemctls_exit_3() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_DAEMON=inactive \
    ssh -o BatchMode=yes root@geoffcloud systemctl is-active --quiet atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]'
  [ "$status" = 3 ] || { echo "exit $status, want 3" >&2; exit 1; }
}

it_times_out_with_exit_255_when_the_host_does_not_answer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_SSH_UNREACHABLE=1 STUB_MEM_AVAILABLE=2048 \
    ssh -o BatchMode=yes root@geoffcloud "free -m | awk '/^Mem:/ {print \$7}'" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host geoffcloud port 22: Connection timed out\r'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
CALLS
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_DAEMON=active \
    ssh -o BatchMode=yes root@other systemctl is-active --quiet atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@other systemctl is-active --quiet atc-daemon'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@other","systemctl","is-active","--quiet","atc-daemon"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_without_batch_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_DAEMON=active \
    ssh root@geoffcloud systemctl is-active --quiet atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: root@geoffcloud systemctl is-active --quiet atc-daemon'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_kubectl_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl delete namespace atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud k3s kubectl delete namespace atc'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","delete","namespace","atc"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud reboot > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@geoffcloud reboot'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","reboot"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for the
# other remote tools, checked so no call can reach a real remote tool, the empty call log,
# and the HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_readiness_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
