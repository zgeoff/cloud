#!/usr/bin/env bash
# Stub test for install-atc-gateway-credentials.sh's rerun check on the saved impd token
# (#37). It touches no host, no 1Password vault and no impd: op, atc-key, ssh, docker and
# curl are stubs, and "the host" is a temporary directory on this machine.
#
#   bash scripts/test-install-atc-gateway-credentials.sh
#
# Every case is a rerun: glm, the daemon bearer and atc-cloud exist, so the script reaches
# step 3's skip. Each case checks the exit status and message, that the script never mints
# or removes a token, and that the saved token reaches no argv and no output.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
failures=0

teardown() {
  rm -rf "$work"
}
trap teardown EXIT

good_token="imp_fixture_$(openssl rand -hex 16)"
stale_token="imp_fixture_$(openssl rand -hex 16)"
bearer="fixture-bearer-$(openssl rand -hex 16)"

mkdir -p "$work/bin" "$work/host-bin"

# local stubs: 1Password holds the bearer item, atc-key exists
cat > "$work/bin/op" << 'EOF'
#!/usr/bin/env bash
printf 'op %s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "vault get") echo '{}' ;;
  "item list") echo '[{"title":"atc-daemon-token"}]' ;;
  "read "*) printf '%s\n' "$STUB_BEARER" ;;
  *) echo "op stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/atc-key" << 'EOF'
#!/usr/bin/env bash
echo "atc-key stub: the rerun must not read the z.ai key" >&2
exit 1
EOF
# ssh runs the host command here, with the host stubs first on PATH
cat > "$work/bin/ssh" << 'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$STUB_LOG"
shift 3
# STUB_REMOVE_TOKEN removes the saved token just before step 3's check, after preflight
# listed it
case "$*" in
  *tokens/whoami*) [ -z "${STUB_REMOVE_TOKEN:-}" ] || rm -f "$ATC_CREDENTIALS_DIR/imp-token" ;;
esac
# everything the host command prints goes to the log too, for the token check
PATH="$STUB_HOST_BIN:$PATH" bash -c "$*" | tee -a "$STUB_LOG.host"
exit "${PIPESTATUS[0]}"
EOF

# host stubs: impd with glm and atc-cloud, install without chown
cat > "$work/host-bin/docker" << 'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  "exec imp-host imp info --json") echo '{"features":{"grantableTokens":true}}' ;;
  "exec imp-host imp secret ls --json")
    echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}]' ;;
  "exec imp-host imp token ls --json")
    echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}]' ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$work/host-bin/install" << 'EOF'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >> "$STUB_LOG"
mkdir -p "${!#}"
EOF
# impd's tokens.whoami, answering as curl -w '\n%{http_code}' prints it. STUB_IMPD picks a
# failure: down (connection refused, exit 7), reset (exit 56), 500 or 403 (that status), or
# garbage (200 with a body that is not JSON). Otherwise a known token gets its identity,
# named STUB_NAME, and any other bearer gets impd's 401.
cat > "$work/host-bin/curl" << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
header="$(cat)"
case "$*" in
  "-q --noproxy * "*"-H @-"*"-w \n%{http_code} http://127.0.0.1:7070/rpc/tokens/whoami") ;;
  *) echo "curl stub: unexpected $*" >&2; exit 2 ;;
esac
case "${STUB_IMPD:-up}" in
  down) echo "curl: (7) Failed to connect to 127.0.0.1 port 7070" >&2; exit 7 ;;
  reset) echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56 ;;
  500) printf '{"json":{"code":"INTERNAL_SERVER_ERROR","status":500}}\n500'; exit 0 ;;
  403) printf '{"json":{"code":"FORBIDDEN","status":403}}\n403'; exit 0 ;;
  garbage) printf '<html>bad gateway</html>\n200'; exit 0 ;;
esac
if [ "$header" = "Authorization: Bearer $STUB_GOOD_TOKEN" ]; then
  printf '{"json":{"kind":"token","name":"%s","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}\n200' \
    "${STUB_NAME:-atc-cloud}"
else
  printf '{"error":"unauthorized"}\n401'
fi
EOF
chmod +x "$work"/bin/* "$work"/host-bin/*

host_bin="$work/host-bin"

# runs one rerun; $1 is the case name, $2 the imp-token file's content (- for empty, @dir
# for a directory in its place, @no-newline for the good token without a trailing
# newline), the rest are stub settings
run_case() {
  local name="$1" content="$2"
  shift 2
  local dir="$work/$name/secrets"
  mkdir -p "$dir"
  printf '%s\n' "$bearer" > "$dir/gateway-token"
  if [ "$content" = - ]; then
    : > "$dir/imp-token"
  elif [ "$content" = @dir ]; then
    mkdir "$dir/imp-token"
  elif [ "$content" = @no-newline ]; then
    printf '%s' "$good_token" > "$dir/imp-token"
  else
    printf '%s\n' "$content" > "$dir/imp-token"
  fi
  : > "$work/$name.log"
  status=0
  env "$@" PATH="$work/bin:$PATH" STUB_HOST_BIN="$host_bin" STUB_LOG="$work/$name.log" \
    STUB_BEARER="$bearer" STUB_GOOD_TOKEN="$good_token" OP_SERVICE_ACCOUNT_TOKEN=fixture \
    ATC_CREDENTIALS_DIR="$dir" bash "$repo/scripts/install-atc-gateway-credentials.sh" \
    > "$work/$name.out" 2>&1 || status=$?
}

# whether any of the files holds the token, also across curl's trace, which wraps a line
# every 64 bytes behind an offset ("0040: ")
has_token() {
  local token="$1" file
  shift
  for file in "$@"; do
    [ -f "$file" ] || continue
    if grep -qF -- "$token" "$file" ||
      sed -E 's/^[0-9a-f]{4}: //' "$file" | tr -d '\n' | grep -qF -- "$token"; then
      return 0
    fi
  done
  return 1
}

check() {
  local name="$1" want_status="$2" want_text="$3"
  local problems=()
  [ "$status" -eq "$want_status" ] || problems+=("exit $status, want $want_status")
  grep -qF -- "$want_text" "$work/$name.out" || problems+=("output lacks: $want_text")
  if grep -qE 'token (new|rm)' "$work/$name.log"; then
    problems+=("minted or removed a token")
  fi
  for token in "$good_token" "$stale_token"; do
    if has_token "$token" "$work/$name.log" "$work/$name.log.host" "$work/$name.out"; then
      problems+=("a token reached argv or output")
    fi
  done
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: ${problems[*]}"
    sed 's/^/    /' "$work/$name.out"
    failures=$((failures + 1))
  fi
}

run_case valid "$good_token"
check valid 0 "skip: both exist, atc-cloud has the expected limits, and the file authenticates as it"

run_case no-newline @no-newline
check no-newline 0 "skip: both exist, atc-cloud has the expected limits, and the file authenticates as it"

run_case empty -
check empty 1 "does not authenticate to impd as the token atc-cloud"
if grep -q '^curl' "$work/empty.log"; then
  echo "FAIL: empty: called impd with no token"
  failures=$((failures + 1))
fi

# atc reads the whole file less one trailing newline, so more than one line is a bad
# token even when the first line is good; impd is never asked
for bad in multiline:"$good_token"$'\nextra' crlf:"$good_token"$'\r' blank-line:"$good_token"$'\n'; do
  run_case "${bad%%:*}" "${bad#*:}"
  check "${bad%%:*}" 1 "does not authenticate to impd as the token atc-cloud"
  if grep -q '^curl' "$work/${bad%%:*}.log"; then
    echo "FAIL: ${bad%%:*}: called impd with a token atc would not send"
    failures=$((failures + 1))
  fi
done

run_case stale "$stale_token"
check stale 1 "does not authenticate to impd as the token atc-cloud"

run_case wrong-identity "$good_token" STUB_NAME=atc-other
check wrong-identity 1 "does not authenticate to impd as the token atc-cloud"

# impd's failures leave the file unchecked: no advice to remove it or revoke atc-cloud
check_unchecked() {
  local name="$1" want_text="$2"
  check "$name" 1 "$want_text"
  if grep -qF "imp token rm" "$work/$name.out"; then
    echo "FAIL: $name: advised removing a token impd never rejected"
    failures=$((failures + 1))
  fi
}

run_case impd-down "$good_token" STUB_IMPD=down
check_unchecked impd-down "the check on the host exited 7"

run_case impd-reset "$good_token" STUB_IMPD=reset
check_unchecked impd-reset "the check on the host exited 56"

run_case impd-500 "$good_token" STUB_IMPD=500
check_unchecked impd-500 "impd answered HTTP 500, so"

run_case impd-403 "$good_token" STUB_IMPD=403
check_unchecked impd-403 "impd answered HTTP 403, so"

run_case impd-garbage "$good_token" STUB_IMPD=garbage
check_unchecked impd-garbage "impd answered HTTP 200 without an identity"

# a saved token the host cannot read is unchecked too, and impd is never asked
check_unreadable() {
  check_unchecked "$1" "the saved token is not a readable regular file on the host"
  if grep -q '^curl' "$work/$1.log"; then
    echo "FAIL: $1: called impd without reading the token"
    failures=$((failures + 1))
  fi
}

run_case removed "$good_token" STUB_REMOVE_TOKEN=1
check_unreadable removed

run_case directory @dir
check_unreadable directory

# Real curl against a local impd stand-in, under a hostile curl config: .curlrc files in
# HOME, CURL_HOME and XDG_CONFIG_HOME that turn on -v and --trace-ascii and set a proxy,
# and every proxy variable pointing at a listener that records what reaches it. The
# token must reach impd's stand-in only: no output, no trace, nothing at the proxy.
cat > "$work/listen.py" << 'EOF'
import os, socket, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

work = sys.argv[1]

class Impd(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        good = self.headers.get("authorization") == "Bearer " + os.environ["STUB_GOOD_TOKEN"]
        if self.path == "/rpc/tokens/whoami" and good:
            status, body = 200, b'{"json":{"kind":"token","name":"atc-cloud"}}'
        else:
            status, body = 401, b'{"error":"unauthorized"}'
        self.send_response(status)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

def run_proxy(server):
    while True:
        conn, _ = server.accept()
        conn.settimeout(2)
        with open(os.path.join(work, "proxy.bytes"), "ab") as out:
            out.write(b"connection\n")
            try:
                out.write(conn.recv(65536))
            except OSError:
                pass
        conn.close()

proxy = socket.socket()
proxy.bind(("127.0.0.1", 0))
proxy.listen()
threading.Thread(target=run_proxy, args=(proxy,), daemon=True).start()
impd = ThreadingHTTPServer(("127.0.0.1", 0), Impd)
with open(os.path.join(work, "ports.tmp"), "w") as out:
    out.write(f"{impd.server_address[1]} {proxy.getsockname()[1]}\n")
os.rename(os.path.join(work, "ports.tmp"), os.path.join(work, "ports"))
impd.serve_forever()
EOF
STUB_GOOD_TOKEN="$good_token" python3 "$work/listen.py" "$work" &
listener=$!
trap 'kill "$listener" 2> /dev/null || true; teardown' EXIT
for _ in $(seq 50); do
  [ -f "$work/ports" ] && break
  sleep 0.1
done
read -r impd_port proxy_port < "$work/ports"
proxy_url="http://127.0.0.1:$proxy_port"

mkdir -p "$work/home" "$work/curl-home" "$work/xdg"
for rc in "$work/home/.curlrc" "$work/curl-home/.curlrc" "$work/xdg/curlrc"; do
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "$proxy_url" > "$rc"
done
printf 'trace-ascii = %s\n' "$work/trace.txt" >> "$work/curl-home/.curlrc"
hostile=(HOME="$work/home" CURL_HOME="$work/curl-home" XDG_CONFIG_HOME="$work/xdg"
  http_proxy="$proxy_url" HTTP_PROXY="$proxy_url" https_proxy="$proxy_url"
  HTTPS_PROXY="$proxy_url" all_proxy="$proxy_url" ALL_PROXY="$proxy_url" NO_PROXY= no_proxy=)

# the controls: plain curl under that config goes through the proxy, and with
# --noproxy alone still traces the token, so a clean real run below proves the
# installer's isolation, not a dead config
printf 'Authorization: Bearer %s\n' "$stale_token" |
  env "${hostile[@]}" curl -sS --max-time 5 -H @- "http://127.0.0.1:$impd_port/rpc/tokens/whoami" \
    > "$work/control.out" 2>&1 || true
if ! grep -q connection "$work/proxy.bytes" 2> /dev/null; then
  echo "FAIL: control: the hostile curl config did not reach the proxy"
  failures=$((failures + 1))
fi
printf 'Authorization: Bearer %s\n' "$stale_token" |
  env "${hostile[@]}" curl --noproxy '*' -sS --max-time 5 -H @- \
    "http://127.0.0.1:$impd_port/rpc/tokens/whoami" > "$work/control.out" 2>&1 || true
if ! has_token "$stale_token" "$work/trace.txt"; then
  echo "FAIL: control: the hostile curl config did not trace the token"
  failures=$((failures + 1))
fi
rm -f "$work/proxy.bytes" "$work/trace.txt"

cp -r "$work/host-bin" "$work/host-bin-real"
rm "$work/host-bin-real/curl"
host_bin="$work/host-bin-real"

# a real run must leave no trace file holding a token and send nothing to the proxy
check_isolated() {
  local name="$1"
  if [ -s "$work/proxy.bytes" ]; then
    echo "FAIL: $name: the proxy received a connection"
    failures=$((failures + 1))
  fi
  if has_token "$good_token" "$work/trace.txt" || has_token "$stale_token" "$work/trace.txt"; then
    echo "FAIL: $name: a token reached curl's trace"
    failures=$((failures + 1))
  fi
  rm -f "$work/proxy.bytes" "$work/trace.txt"
}

# CURL_HOME's .curlrc traces to a file
run_case real-curl-valid "$good_token" "${hostile[@]}" ATC_IMPD_PORT="$impd_port"
check real-curl-valid 0 "skip: both exist, atc-cloud has the expected limits, and the file authenticates as it"
check_isolated real-curl-valid

run_case real-curl-stale "$stale_token" "${hostile[@]}" ATC_IMPD_PORT="$impd_port"
check real-curl-stale 1 "does not authenticate to impd as the token atc-cloud"
check_isolated real-curl-stale

# HOME's .curlrc alone traces to stdout, which the host command returns here
run_case real-curl-home "$good_token" "${hostile[@]}" CURL_HOME= XDG_CONFIG_HOME= \
  ATC_IMPD_PORT="$impd_port"
check real-curl-home 0 "skip: both exist, atc-cloud has the expected limits, and the file authenticates as it"
check_isolated real-curl-home

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
