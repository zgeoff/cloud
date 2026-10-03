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
PATH="$STUB_HOST_BIN:$PATH" exec bash -c "$*"
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
# impd's tokens.whoami. With STUB_IMPD set to down it refuses the connection; otherwise a
# known token gets its identity, named STUB_NAME, and any other bearer gets impd's 401
cat > "$work/host-bin/curl" << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
if [ "${STUB_IMPD:-up}" = down ]; then
  echo "curl: (7) Failed to connect to 127.0.0.1 port 7070" >&2
  exit 7
fi
header="$(cat)"
case "$*" in
  *"-H @-"*"http://127.0.0.1:7070/rpc/tokens/whoami"*) ;;
  *) echo "curl stub: unexpected $*" >&2; exit 2 ;;
esac
if [ "$header" = "Authorization: Bearer $STUB_GOOD_TOKEN" ]; then
  printf '{"json":{"kind":"token","name":"%s","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}\n' \
    "${STUB_NAME:-atc-cloud}"
else
  echo '{"json":{"defined":false,"code":"UNAUTHORIZED","status":401,"message":"Unauthorized"}}'
  exit 22
fi
EOF
chmod +x "$work"/bin/* "$work"/host-bin/*

# runs one rerun; $1 is the case name, $2 the imp-token file's content (- for empty), the
# rest are stub settings
run_case() {
  local name="$1" content="$2"
  shift 2
  local dir="$work/$name/secrets"
  mkdir -p "$dir"
  printf '%s\n' "$bearer" > "$dir/gateway-token"
  if [ "$content" = - ]; then
    : > "$dir/imp-token"
  else
    printf '%s\n' "$content" > "$dir/imp-token"
  fi
  : > "$work/$name.log"
  status=0
  env "$@" PATH="$work/bin:$PATH" STUB_HOST_BIN="$work/host-bin" STUB_LOG="$work/$name.log" \
    STUB_BEARER="$bearer" STUB_GOOD_TOKEN="$good_token" OP_SERVICE_ACCOUNT_TOKEN=fixture \
    ATC_CREDENTIALS_DIR="$dir" bash "$repo/scripts/install-atc-gateway-credentials.sh" \
    > "$work/$name.out" 2>&1 || status=$?
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
    if grep -qF -- "$token" "$work/$name.log" "$work/$name.out"; then
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

run_case empty -
check empty 1 "does not authenticate to impd as the token atc-cloud"
if grep -q '^curl' "$work/empty.log"; then
  echo "FAIL: empty: called impd with no token"
  failures=$((failures + 1))
fi

run_case stale "$stale_token"
check stale 1 "does not authenticate to impd as the token atc-cloud"

run_case wrong-identity "$good_token" STUB_NAME=atc-other
check wrong-identity 1 "does not authenticate to impd as the token atc-cloud"

run_case impd-down "$good_token" STUB_IMPD=down
check impd-down 1 "impd did not answer on the host's 127.0.0.1:7070"

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
