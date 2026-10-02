#!/usr/bin/env bash
# Read-only readiness checks for the atc-gateway plan (docs/plans/atc-gateway.md).
# Prints one line per check: ok, missing (expected before the deploy) or FAIL. It
# changes nothing, and prints nothing secret.
set -uo pipefail

host="${1:-geoffcloud}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

print_check() {
  printf '%-8s %s\n' "$1" "$2"
  if [ "$1" = FAIL ]; then failures=$((failures + 1)); fi
}

run_kubectl() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$host" k3s kubectl "$@" 2>/dev/null
}

# the cluster
if [ "$(run_kubectl get nodes --no-headers | awk '{print $2}')" = Ready ]; then
  print_check ok "k3s node on $host is Ready"
else
  print_check FAIL "k3s node on $host is not Ready, or $host is unreachable over the tailnet"
fi

free_mib=$(ssh -o BatchMode=yes "root@$host" "free -m | awk '/^Mem:/ {print \$7}'" 2>/dev/null)
if [ "${free_mib:-0}" -ge 1024 ]; then
  print_check ok "host has ${free_mib} MiB available (gateway needs 256 MiB)"
else
  print_check FAIL "host has ${free_mib:-?} MiB available"
fi

if [ "$(run_kubectl -n ingress get deploy cloudflared -o jsonpath='{.status.readyReplicas}')" -ge 1 ] 2>/dev/null; then
  print_check ok "cloudflared has ready replicas"
else
  print_check FAIL "cloudflared has no ready replica"
fi

# what the deploy creates
for resource in "namespace atc" "storageclass local-path-retain" "-n atc deploy atc-gateway"; do
  # shellcheck disable=SC2086
  if run_kubectl get $resource > /dev/null; then
    print_check ok "exists: $resource"
  else
    print_check missing "$resource"
  fi
done

# the image
token=$(curl -s "https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull" | jq -r '.token // empty')
if [ -n "$token" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
  https://ghcr.io/v2/zgeoff/atc-gateway/tags/list)" = 200 ]; then
  print_check ok "image ghcr.io/zgeoff/atc-gateway exists"
else
  print_check missing "image ghcr.io/zgeoff/atc-gateway"
fi

# the public route
if getent hosts atc.geoff.cloud > /dev/null; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp)
  print_check "$([ "$code" = 200 ] && echo ok || echo FAIL)" "atc.geoff.cloud protected-resource metadata: $code"
else
  print_check missing "DNS record atc.geoff.cloud"
fi

# the tailnet policy, as code
if grep -q "tag:atc-daemon" "$repo/infra/tailnet-policy.ts"; then
  print_check ok "tailnet policy defines tag:atc-daemon"
else
  print_check missing "tailnet tag:atc-daemon and its grants"
fi

exit "$failures"
