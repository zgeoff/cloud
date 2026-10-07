#!/usr/bin/env bash
# Test for start-stub-proxy.sh: the proxy stand-in records each connection with the first
# bytes it receives, including a connection that a .curlrc in HOME routes to it. That
# last case is the control for the credentials suite's hostile curl config: a plain curl
# under such a config reaches this proxy, so a suite case that finds no connection proves
# the script's isolation, not a dead config.
#
#   bash scripts/test-lib/test-start-stub-proxy.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-proxy.sh"

it_records_each_connection_with_its_first_bytes() {
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin curl -q -sS --max-time 5 -x "http://127.0.0.1:$(cat "$tree/proxy/port")" \
    http://example.invalid/first > /dev/null 2>&1 || true
  env -i PATH=/usr/bin:/bin curl -q -sS --max-time 5 -x "http://127.0.0.1:$(cat "$tree/proxy/port")" \
    http://example.invalid/second > /dev/null 2>&1 || true

  diff - <(tr -d '\r' < "$tree/proxy/connections" | grep -E '^(connection|GET )') << 'LINES'
connection
GET http://example.invalid/first HTTP/1.1
connection
GET http://example.invalid/second HTTP/1.1
LINES
}

it_records_no_connection_until_one_arrives() {
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"

  ls -A "$tree/proxy" > "$tree/files"

  diff - "$tree/files" << 'FILES'
pid
port
FILES
}

it_receives_a_plain_curl_that_a_curlrc_in_HOME_routes_to_it() {
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$(cat "$tree/proxy/port")" > "$tree/home/.curlrc"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" http_proxy="http://127.0.0.1:$(cat "$tree/proxy/port")" \
    curl -sS --max-time 5 http://127.0.0.1:1/rpc/tokens/whoami > /dev/null 2>&1 || true

  diff - <(tr -d '\r' < "$tree/proxy/connections" | grep -E '^(connection|GET )') << 'LINES'
connection
GET http://127.0.0.1:1/rpc/tokens/whoami HTTP/1.1
LINES
}

# Runtime every case needs: the stand-in, started in <tree>/proxy.
setup_test() {
  local tree="$1"
  mkdir "$tree/proxy"
  start_stub_proxy "$tree/proxy"
}

run_cases
