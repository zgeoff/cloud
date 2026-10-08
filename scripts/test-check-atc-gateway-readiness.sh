#!/usr/bin/env bash
# Hermetic test for check-atc-gateway-readiness.sh: it prints one ok, missing or FAIL line
# per readiness check and exits with the number of FAIL lines; missing is no failure. It
# touches no host, registry, DNS or route: ssh, curl and getent are stand-ins from test-lib
# that log their argv as JSON lines and answer from the case's tree, where the cluster's
# objects are files, the DNS records a hosts file, and infra/tailnet-policy.ts the policy
# the script greps. Each case runs the script under `env -i` with only the variables it
# sets and compares its whole stdout, stderr and call log, and its exact exit code.
#
#   bash scripts/test-check-atc-gateway-readiness.sh
#   CASE='memory' bash scripts/test-check-atc-gateway-readiness.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-readiness-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-readiness-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-getent.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_reports_every_check_ok_once_the_gateway_is_deployed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_reports_what_the_deploy_creates_as_missing_and_exits_0_before_the_deploy() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/deploy/ingress"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['home-pc'], ip: ['tcp:8413'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_DAEMON=inactive \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
missing  namespace atc
missing  storageclass local-path-retain
missing  -n atc deploy atc-gateway
missing  image ghcr.io/zgeoff/atc-gateway
missing  DNS record atc.geoff.cloud
missing  tailnet grant tag:cloud -> tag:imp:7070
missing  atc-daemon service on geoffcloud
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_three_host_checks_and_exits_3_when_the_host_does_not_answer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 STUB_SSH_UNREACHABLE=1 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
FAIL     k3s node on geoffcloud is not Ready, or geoffcloud is unreachable over the tailnet
FAIL     host has ? MiB available
FAIL     cloudflared has no ready replica
missing  namespace atc
missing  storageclass local-path-retain
missing  -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
missing  atc-daemon service on geoffcloud
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
CALLS
  [ "$status" = 3 ] || { echo "exit $status, want 3" >&2; exit 1; }
}

it_fails_the_node_check_and_exits_1_when_the_node_is_not_Ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   NotReady control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
FAIL     k3s node on geoffcloud is not Ready, or geoffcloud is unreachable over the tailnet
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_the_memory_check_and_exits_1_below_1024_MiB_available() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=1023 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
FAIL     host has 1023 MiB available
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_passes_the_memory_check_at_exactly_1024_MiB_available() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=1024 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 1024 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_cloudflared_check_and_exits_1_when_no_replica_is_ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  : > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
FAIL     cloudflared has no ready replica
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_two_checks_and_exits_2_when_the_node_is_not_Ready_and_memory_is_low() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   NotReady control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=512 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
FAIL     k3s node on geoffcloud is not Ready, or geoffcloud is unreachable over the tailnet
FAIL     host has 512 MiB available
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_reports_the_image_missing_when_ghcr_does_not_answer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_UNREACHABLE=1 STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
missing  image ghcr.io/zgeoff/atc-gateway
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_public_route_and_exits_1_when_its_metadata_answers_another_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=530 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
FAIL     atc.geoff.cloud protected-resource metadata: 530
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_the_public_route_with_000_and_exits_1_when_its_metadata_times_out() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
FAIL     atc.geoff.cloud protected-resource metadata: 000
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_the_in_cluster_check_and_exits_1_when_the_gateway_answers_another_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_NODE_LINE='geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=403 \
    bash scripts/check-atc-gateway-readiness.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud
FAIL     gateway in-cluster metadata: 403
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_checks_the_named_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/cluster/namespace" "$tree/cluster/storageclass" "$tree/cluster/deploy/ingress" "$tree/cluster/deploy/atc"
  touch "$tree/cluster/namespace/atc" "$tree/cluster/storageclass/local-path-retain"
  printf 1 > "$tree/cluster/deploy/ingress/cloudflared"
  printf 1 > "$tree/cluster/deploy/atc/atc-gateway"
  echo '104.21.32.1 atc.geoff.cloud' > "$tree/hosts"
  printf '%s\n' 'grants: [' "  { src: ['tag:cloud'], dst: ['tag:imp'], ip: ['tcp:7070'] }," ']' > "$tree/infra/tailnet-policy.ts"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud-2 STUB_NODE_LINE='geoffcloud-2   Ready    control-plane,master   40d   v1.33.4+k3s1' STUB_MEM_AVAILABLE=2048 \
    STUB_GHCR_IMAGE=present STUB_ROUTE_CODE=200 STUB_DAEMON=active STUB_PROBE_CODE=200 \
    bash scripts/check-atc-gateway-readiness.sh geoffcloud-2) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
ok       k3s node on geoffcloud-2 is Ready
ok       host has 2048 MiB available (gateway needs 256 MiB)
ok       cloudflared has ready replicas
ok       exists: namespace atc
ok       exists: storageclass local-path-retain
ok       exists: -n atc deploy atc-gateway
ok       image ghcr.io/zgeoff/atc-gateway exists
ok       atc.geoff.cloud protected-resource metadata: 200
ok       tailnet grant tag:cloud -> tag:imp:7070
ok       atc-daemon is active on geoffcloud-2
ok       gateway in-cluster metadata: 200
OUT
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","get","nodes","--no-headers"]
["ssh","-o","BatchMode=yes","root@geoffcloud-2","free -m | awk '/^Mem:/ {print $7}'"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","-n","ingress","get","deploy","cloudflared","-o","jsonpath={.status.readyReplicas}"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","get","namespace","atc"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","get","storageclass","local-path-retain"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","get","-n","atc","deploy","atc-gateway"]
["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]
["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]
["getent","hosts","atc.geoff.cloud"]
["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]
["ssh","-o","BatchMode=yes","root@geoffcloud-2","systemctl","is-active","--quiet","atc-daemon"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","-n","atc","get","deploy","atc-gateway"]
["ssh","-o","BatchMode=yes","-o","ConnectTimeout=15","root@geoffcloud-2","k3s","kubectl","-n","atc","run","readiness-probe","--rm","-i","--restart=Never","--quiet","--image=curlimages/curl:8.16.0","--","curl","-s","-o","/dev/null","-w","%{http_code}","-H","Host: atc.geoff.cloud","http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>/scripts, where it finds <tree>/infra as
# its repo's; the ssh, curl and getent stand-ins with fail-closed stand-ins for the other
# remote tools in <tree>/bin, checked so no call can reach a real remote tool; the
# empty call log; and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/scripts" "$tree/infra"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/check-atc-gateway-readiness.sh" "$tree/scripts/"
  create_stub_readiness_ssh "$tree/bin"
  create_stub_readiness_curl "$tree/bin"
  create_stub_getent "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
