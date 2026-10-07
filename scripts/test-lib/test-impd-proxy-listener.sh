#!/usr/bin/env bash
# Test for impd-proxy-listener.py and the hostile curl config the credentials suite runs
# under. The last two cases are that config's controls: plain curl under it goes through
# the proxy, and curl with --noproxy alone still traces the bearer, so a suite case that
# finds no proxy connection and no trace proves the script's isolation, not a dead config.
#
#   bash scripts/test-lib/test-impd-proxy-listener.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/build-token.sh"

it_answers_whoami_with_atc_clouds_identity_for_the_good_bearer() {
  local seed="$1" listener_py="$2" good_token impd_port proxy_port code
  listener=""
  tree="$(mktemp -d)"
  trap 'if [ -n "$listener" ]; then kill "$listener" 2> /dev/null || true; fi; rm -rf "$tree"' EXIT
  good_token="$(build_token "$seed" good)"
  STUB_GOOD_TOKEN="$good_token" python3 "$listener_py" "$tree" &
  listener=$!
  wait_for 10 "the listener's ports file" test -f "$tree/ports"
  read -r impd_port proxy_port < "$tree/ports"

  code="$(printf 'Authorization: Bearer %s\n' "$good_token" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$impd_port/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_whoami_with_401_for_another_bearer() {
  local seed="$1" listener_py="$2" impd_port proxy_port code
  listener=""
  tree="$(mktemp -d)"
  trap 'if [ -n "$listener" ]; then kill "$listener" 2> /dev/null || true; fi; rm -rf "$tree"' EXIT
  STUB_GOOD_TOKEN="$(build_token "$seed" good)" python3 "$listener_py" "$tree" &
  listener=$!
  wait_for 10 "the listener's ports file" test -f "$tree/ports"
  read -r impd_port proxy_port < "$tree/ports"

  code="$(printf 'Authorization: Bearer %s\n' "$(build_token "$seed" stale)" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$impd_port/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"unauthorized"}'
  [ "$code" = 401 ] || { echo "HTTP $code, want 401" >&2; exit 1; }
}

it_records_each_proxy_connection_with_its_first_bytes() {
  local seed="$1" listener_py="$2" impd_port proxy_port
  listener=""
  tree="$(mktemp -d)"
  trap 'if [ -n "$listener" ]; then kill "$listener" 2> /dev/null || true; fi; rm -rf "$tree"' EXIT
  STUB_GOOD_TOKEN="$(build_token "$seed" good)" python3 "$listener_py" "$tree" &
  listener=$!
  wait_for 10 "the listener's ports file" test -f "$tree/ports"
  read -r impd_port proxy_port < "$tree/ports"

  env -i PATH=/usr/bin:/bin curl -q -sS --max-time 5 -x "http://127.0.0.1:$proxy_port" \
    http://example.invalid/probe > /dev/null 2>&1 || true

  diff - <(head -n 2 "$tree/proxy.bytes" | tr -d '\r') << 'EOF'
connection
GET http://example.invalid/probe HTTP/1.1
EOF
}

it_routes_a_plain_curl_through_the_proxy_under_the_hostile_config() {
  local seed="$1" listener_py="$2" impd_port proxy_port
  listener=""
  tree="$(mktemp -d)"
  trap 'if [ -n "$listener" ]; then kill "$listener" 2> /dev/null || true; fi; rm -rf "$tree"' EXIT
  STUB_GOOD_TOKEN="$(build_token "$seed" good)" python3 "$listener_py" "$tree" &
  listener=$!
  wait_for 10 "the listener's ports file" test -f "$tree/ports"
  read -r impd_port proxy_port < "$tree/ports"
  mkdir "$tree/home"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"

  printf 'Authorization: Bearer %s\n' "$(build_token "$seed" stale)" |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" http_proxy="http://127.0.0.1:$proxy_port" \
      curl -sS --max-time 5 -H @- "http://127.0.0.1:$impd_port/rpc/tokens/whoami" \
      > /dev/null 2>&1 || true

  diff - <(head -n 1 "$tree/proxy.bytes") <<< connection
}

it_traces_the_bearer_when_curl_runs_with_noproxy_alone_under_the_hostile_config() {
  local seed="$1" listener_py="$2" stale_token impd_port proxy_port
  listener=""
  tree="$(mktemp -d)"
  trap 'if [ -n "$listener" ]; then kill "$listener" 2> /dev/null || true; fi; rm -rf "$tree"' EXIT
  stale_token="$(build_token "$seed" stale)"
  STUB_GOOD_TOKEN="$(build_token "$seed" good)" python3 "$listener_py" "$tree" &
  listener=$!
  wait_for 10 "the listener's ports file" test -f "$tree/ports"
  read -r impd_port proxy_port < "$tree/ports"
  mkdir "$tree/curl-home"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$proxy_port" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"

  printf 'Authorization: Bearer %s\n' "$stale_token" |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" CURL_HOME="$tree/curl-home" \
      curl --noproxy '*' -sS --max-time 5 -H @- "http://127.0.0.1:$impd_port/rpc/tokens/whoami" \
      > /dev/null 2>&1 || true

  [ -f "$tree/trace.txt" ] || { echo "curl wrote no trace" >&2; exit 1; }
  sed -E 's/^[0-9a-f]{4}: //' "$tree/trace.txt" | tr -d '\n' | grep -qF -- "$stale_token" ||
    { echo "the trace does not hold the bearer" >&2; exit 1; }
}

listener_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/impd-proxy-listener.py"
seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
echo "seed $seed (rerun with SEED=$seed)"
run_cases "$seed" "$listener_py"
