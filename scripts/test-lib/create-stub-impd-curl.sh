# shellcheck shell=bash
# create_stub_impd_curl <bin>: writes <bin>/curl, a stand-in for curl on the host calling
# impd's tokens.whoami on 127.0.0.1:7070, answering as curl -w '\n%{http_code}' prints it.
# It logs each call's argv as a JSON line to STUB_TREE/calls and reads the header from its
# stdin. The bearer STUB_GOOD_TOKEN gets atc-cloud's identity (200, in imp's
# {"json": Identity} envelope) and any other bearer impd's 401 {"error":"unauthorized"};
# STUB_WHOAMI_STATUS and STUB_WHOAMI_BODY set a fixed answer; STUB_CURL_EXIT=56 fails as
# curl does when the connection is reset. A call with other arguments ends with exit 97
# and "unexpected: <argv>" on stderr.
create_stub_impd_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
header="$(cat)"
if [ "$*" != '-q --noproxy * -sS --max-time 10 -H @- -H content-type: application/json --data {"json":{}} -w \n%{http_code} http://127.0.0.1:7070/rpc/tokens/whoami' ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
case "${STUB_CURL_EXIT:-}" in
  56) echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56 ;;
esac
if [ -n "${STUB_WHOAMI_STATUS:-}" ]; then
  printf '%s\n%s' "$STUB_WHOAMI_BODY" "$STUB_WHOAMI_STATUS"
elif [ "$header" = "Authorization: Bearer ${STUB_GOOD_TOKEN:-}" ]; then
  printf '%s\n200' '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
else
  printf '%s\n401' '{"error":"unauthorized"}'
fi
STUB
  chmod +x "$bin/curl"
}
