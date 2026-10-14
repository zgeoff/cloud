# shellcheck shell=bash
# create_stub_readiness_curl <bin>: writes <bin>/curl, a stand-in for curl as
# check-atc-gateway-readiness.sh calls it: ghcr.io's anonymous pull token and tag list for
# zgeoff/atc-gateway, and the public route's protected-resource metadata. It logs each
# call's argv as a JSON line to STUB_TREE/calls and answers:
#
# - `-s https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull`: ghcr's
#   {"token": …} body with the token ghcr-t1;
# - `-s -o /dev/null -w %{http_code} -H Authorization: Bearer <token>
#   https://ghcr.io/v2/zgeoff/atc-gateway/tags/list`: 200 when STUB_GHCR_IMAGE is present
#   and the bearer is that token, 401 for another bearer, else 404;
# - `-s -o /dev/null -w %{http_code} --max-time 10
#   https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp`: STUB_ROUTE_CODE, or,
#   when it is unset, curl's timeout: 000 and exit 28;
# - with STUB_GHCR_UNREACHABLE=1, both ghcr calls fail as curl -s does when it cannot
#   resolve a host: exit 6, with nothing printed but 000 for -w %{http_code}.
#
# Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Not checked against ghcr.io or the route (no test reaches the internet); the token value
# is a fixture. Checked on 2026-10-08 against these documents:
#
# - https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md : the tag list,
#   GET /v2/<name>/tags/list (end-8a), answers 200, or 404 for a repository the registry
#   does not know (NAME_UNKNOWN);
# - https://distribution.github.io/distribution/spec/auth/token/ : a registry answers a
#   request without a valid bearer with 401, and the token endpoint answers a JSON body
#   with a "token" field;
# - https://curl.se/docs/manpage.html (EXIT CODES), the same for curl 8.5.0 (CI's
#   ubuntu-24.04 runner image 20261004) and 8.22.0: 6 "Could not resolve host" and 28
#   "Operation timeout". test-create-stub-readiness-curl.sh pins the 000 that -w
#   %{http_code} prints after a failed transfer against the real curl.
#
# The documents do not settle, so they stay as they were and need a ghcr.io sample: the
# other fields of ghcr's token body (the token spec allows access_token, expires_in and
# issued_at, left out here); that ghcr answers 401, not 403 or 404, to a bearer it did not
# issue; and that ghcr out of reach fails as an unresolved host (6) rather than a refused
# connection (7) or a timeout (28).
create_stub_readiness_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
token=ghcr-t1
case "$*" in
  "-s https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull")
    if [ -n "${STUB_GHCR_UNREACHABLE:-}" ]; then exit 6; fi
    printf '{"token":"%s"}' "$token"
    ;;
  "-s -o /dev/null -w %{http_code} -H Authorization: Bearer "*" https://ghcr.io/v2/zgeoff/atc-gateway/tags/list")
    [ "$#" = 8 ] || { echo "unexpected: $*" >&2; exit 97; }
    if [ -n "${STUB_GHCR_UNREACHABLE:-}" ]; then printf 000; exit 6; fi
    if [ "$7" != "Authorization: Bearer $token" ]; then
      printf 401
    elif [ "${STUB_GHCR_IMAGE:-}" = present ]; then
      printf 200
    else
      printf 404
    fi
    ;;
  "-s -o /dev/null -w %{http_code} --max-time 10 https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp")
    if [ -z "${STUB_ROUTE_CODE:-}" ]; then printf 000; exit 28; fi
    printf '%s' "$STUB_ROUTE_CODE"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/curl"
}
