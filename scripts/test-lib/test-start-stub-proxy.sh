#!/usr/bin/env bash
# Test for start-stub-proxy.sh: the proxy stand-in records each connection with the first
# bytes it receives, including a connection that a .curlrc in HOME routes to it. The last
# two cases are the controls for the credentials suite's hostile curl configs, pinning
# what that suite assumes about real curl (8.5.0 and 8.22.0): a plain curl under a .curlrc in
# HOME reaches this proxy, and curl with --noproxy alone, without -q, still reads
# CURL_HOME's .curlrc and traces the bearer. So a suite case that finds no connection or
# no trace proves the script's isolation, not a dead config. Each curl sends an empty
# User-Agent, so the recorded request does not carry curl's version.
#
#   bash scripts/test-lib/test-start-stub-proxy.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-one-of-outputs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-proxy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-impd.sh"

it_records_each_connection_with_its_first_bytes() {
  local first=0 second=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q -sS --max-time 5 \
    -H 'User-Agent:' -x "http://127.0.0.1:$(cat "$tree/proxy/port")" \
    http://example.invalid/first > "$tree/first-out" 2> "$tree/first-err" || first=$?
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q -sS --max-time 5 \
    -H 'User-Agent:' -x "http://127.0.0.1:$(cat "$tree/proxy/port")" \
    http://example.invalid/second > "$tree/second-out" 2> "$tree/second-err" || second=$?

  # each request's lines end in CR LF, as curl sends them; the proxy's own line in LF
  printf 'connection\n%s\r\nHost: example.invalid\r\nAccept: */*\r\nProxy-Connection: Keep-Alive\r\n\r\n' \
    'GET http://example.invalid/first HTTP/1.1' 'GET http://example.invalid/second HTTP/1.1' > "$tree/want-connections"
  diff "$tree/want-connections" "$tree/proxy/connections"
  diff /dev/null "$tree/first-out"
  diff /dev/null "$tree/second-out"
  diff - "$tree/first-err" <<< 'curl: (52) Empty reply from server'
  diff - "$tree/second-err" <<< 'curl: (52) Empty reply from server'
  [ "$first" = 52 ] || { echo "first exit $first, want 52" >&2; exit 1; }
  [ "$second" = 52 ] || { echo "second exit $second, want 52" >&2; exit 1; }
}

it_records_no_connection_until_one_arrives() {
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  ls -A "$tree/proxy" > "$tree/files"

  diff - "$tree/files" << 'FILES'
pid
port
FILES
}

it_receives_a_plain_curl_that_a_curlrc_in_HOME_routes_to_it() {
  local port status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/proxy/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  port="$(cat "$tree/proxy/port")"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$port" > "$tree/home/.curlrc"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" http_proxy="http://127.0.0.1:$port" \
    curl -sS --max-time 5 -H 'User-Agent:' http://127.0.0.1:1/rpc/tokens/whoami \
    > "$tree/out" 2> "$tree/err" || status=$?

  # the request's lines end in CR LF, as curl sends them; the proxy's own line in LF
  printf 'connection\nGET http://127.0.0.1:1/rpc/tokens/whoami HTTP/1.1\r\nHost: 127.0.0.1:1\r\nAccept: */*\r\nProxy-Connection: Keep-Alive\r\n\r\n' \
    > "$tree/want-connections"
  diff "$tree/want-connections" "$tree/proxy/connections"
  # curl's own source port is the kernel's pick, so it is masked. curl 8.5.0 (CI's ubuntu-24.04
  # runner image 20261004) and 8.22.0 word the trace's info lines differently; the case accepts
  # either whole trace, each with the same stderr and exit 52.
  sed -E 's/ from 127\.0\.0\.1 port [0-9]+ $/ from 127.0.0.1 port CLIENT /' "$tree/out" > "$tree/out-masked"
  cat > "$tree/out-curl-8.22" << OUT
*   Trying 127.0.0.1:$port...
* Established connection to 127.0.0.1 (127.0.0.1 port $port) from 127.0.0.1 port CLIENT 
* using HTTP/1.x
=> Send header, 115 bytes (0x73)
0000: GET http://127.0.0.1:1/rpc/tokens/whoami HTTP/1.1
0033: Host: 127.0.0.1:1
0046: Accept: */*
0053: Proxy-Connection: Keep-Alive
0071: 
* Request completely sent off
* Empty reply from server
* shutting down connection #0
OUT
  cat > "$tree/out-curl-8.5" << OUT
== Info:   Trying 127.0.0.1:$port...
== Info: Connected to 127.0.0.1 (127.0.0.1) port $port
=> Send header, 115 bytes (0x73)
0000: GET http://127.0.0.1:1/rpc/tokens/whoami HTTP/1.1
0033: Host: 127.0.0.1:1
0046: Accept: */*
0053: Proxy-Connection: Keep-Alive
0071: 
== Info: Empty reply from server
== Info: Closing connection
OUT
  cat > "$tree/want-err" << 'ERR'
Warning: --trace-ascii overrides an earlier trace/verbose option
curl: (52) Empty reply from server
ERR
  assert_one_of_outputs "a plain curl under the .curlrc" "$tree/out-masked" "$tree/err" "$status" \
    "curl 8.5.0" "$tree/out-curl-8.5" "$tree/want-err" 52 \
    "curl 8.22.0" "$tree/out-curl-8.22" "$tree/want-err" 52
}

# The control for the credentials suite's hostile-config cases. It runs curl itself, not
# the script, because what it pins is real curl's reading of that config: the same POST
# the script sends, with --noproxy alone and without -q, reaches the impd stand-in and gets
# its 401 for the bearer, with no connection to this proxy, while CURL_HOME's .curlrc,
# which names this proxy, still turns on the trace, and the trace holds the bearer.
it_is_bypassed_by_curl_with_noproxy_alone_that_still_traces_under_CURL_HOMEs_curlrc() {
  local impd_port status=0
  tree="$(mktemp -d)"
  trap 'kill $(cat "$tree/impd/pid" "$tree/proxy/pid" 2> /dev/null) 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" impd
  mkdir "$tree/curl-home"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$(cat "$tree/proxy/port")" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"

  printf 'Authorization: Bearer %s\n' imp_fixture_bearer |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" CURL_HOME="$tree/curl-home" \
      curl --noproxy '*' -sS --max-time 5 -H @- -H 'User-Agent:' -H 'content-type: application/json' \
      --data '{"json":{}}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami" \
      > "$tree/out" 2> "$tree/err" || status=$?

  printf '{"error":"unauthorized"}' | diff - "$tree/out"
  ls -A "$tree/impd" > "$tree/impd-files"
  diff - "$tree/impd-files" << FILES
pid
port
FILES
  ls -A "$tree/proxy" > "$tree/proxy-files"
  diff - "$tree/proxy-files" << FILES
pid
port
FILES
  # The whole trace: curl's own source port is the kernel's pick and impd's Date header the
  # wall clock, so both are masked. curl 8.5.0 (CI's ubuntu-24.04 runner image 20261004)
  # and 8.22.0 word the trace's info lines differently; the case accepts either whole
  # trace, each with the same stderr and exit 0.
  impd_port="$(cat "$tree/impd/port")"
  sed -E -e 's/ from 127\.0\.0\.1 port [0-9]+ $/ from 127.0.0.1 port CLIENT /' \
    -e 's/^0000: Date: .+ GMT$/0000: Date: DATE/' "$tree/trace.txt" > "$tree/trace-masked"
  cat > "$tree/trace-curl-8.22" << TRACE
*   Trying 127.0.0.1:$impd_port...
* Established connection to 127.0.0.1 (127.0.0.1 port $impd_port) from 127.0.0.1 port CLIENT 
* using HTTP/1.x
=> Send header, 166 bytes (0xa6)
0000: POST /rpc/tokens/whoami HTTP/1.1
0022: Host: 127.0.0.1:$impd_port
0039: Accept: */*
0046: Authorization: Bearer imp_fixture_bearer
0070: content-type: application/json
0090: Content-Length: 11
00a4: 
=> Send data, 11 bytes (0xb)
0000: {"json":{}}
* upload completely sent off: 11 bytes
* HTTP 1.0, assume close after body
<= Recv header, 27 bytes (0x1b)
0000: HTTP/1.0 401 Unauthorized
<= Recv header, 37 bytes (0x25)
0000: Date: DATE
<= Recv header, 32 bytes (0x20)
0000: content-type: application/json
<= Recv header, 20 bytes (0x14)
0000: content-length: 24
<= Recv header, 2 bytes (0x2)
0000: 
<= Recv data, 24 bytes (0x18)
0000: {"error":"unauthorized"}
* shutting down connection #0
TRACE
  cat > "$tree/trace-curl-8.5" << TRACE
== Info:   Trying 127.0.0.1:$impd_port...
== Info: Connected to 127.0.0.1 (127.0.0.1) port $impd_port
=> Send header, 166 bytes (0xa6)
0000: POST /rpc/tokens/whoami HTTP/1.1
0022: Host: 127.0.0.1:$impd_port
0039: Accept: */*
0046: Authorization: Bearer imp_fixture_bearer
0070: content-type: application/json
0090: Content-Length: 11
00a4: 
=> Send data, 11 bytes (0xb)
0000: {"json":{}}
== Info: HTTP 1.0, assume close after body
<= Recv header, 27 bytes (0x1b)
0000: HTTP/1.0 401 Unauthorized
<= Recv header, 37 bytes (0x25)
0000: Date: DATE
<= Recv header, 32 bytes (0x20)
0000: content-type: application/json
<= Recv header, 20 bytes (0x14)
0000: content-length: 24
<= Recv header, 2 bytes (0x2)
0000: 
<= Recv data, 24 bytes (0x18)
0000: {"error":"unauthorized"}
== Info: Closing connection
TRACE
  printf '%s\n' "Warning: --trace-ascii overrides an earlier trace/verbose option" > "$tree/want-err"
  assert_one_of_outputs "the trace under CURL_HOME's .curlrc" "$tree/trace-masked" "$tree/err" "$status" \
    "curl 8.5.0" "$tree/trace-curl-8.5" "$tree/want-err" 0 \
    "curl 8.22.0" "$tree/trace-curl-8.22" "$tree/want-err" 0
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# Runtime every case needs: the stand-in, started in <tree>/proxy, and the HOME and
# TMPDIR each curl runs with. The config names what a case wires on top: impd, the impd
# stand-in that a curl bypassing the proxy calls, started in <tree>/impd.
setup_test() {
  local tree="$1" part
  mkdir "$tree/proxy" "$tree/home" "$tree/tmp"
  start_stub_proxy "$tree/proxy"
  for part in "${@:2}"; do
    case "$part" in
      impd) mkdir "$tree/impd" && start_stub_impd "$tree/impd" ;;
    esac
  done
}

run_cases
