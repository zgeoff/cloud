#!/usr/bin/env bash
# Runs as root on geoffcloud. check-atc-gateway-readiness.ts sends this file on ssh's stdin:
#
#   ssh root@geoffcloud bash -s -- <impd port>
#
# It reads impd's /health on host loopback, as nixos/modules/impd-local-health.sh does, and
# prints the HTTP status on its first line and impd's body after it, at most 64 KiB, for
# check-impd-health.ts to parse as JSON. curl prints 000 when nothing answers. curl runs with -q
# first (no .curlrc), --noproxy '*' and no proxy variables, so no config on the host can route
# the request off loopback.
set -uo pipefail
export LC_ALL=C

read_impd_health() {
  local port="$1" code
  body="$(mktemp)"
  trap 'rm -f "$body"' EXIT
  code="$(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    -u no_proxy -u NO_PROXY \
    curl -q --noproxy '*' -s -o "$body" -w '%{http_code}' --max-time 10 \
    "http://127.0.0.1:$port/health")"
  printf '%s\n' "${code:-000}"
  head -c 65536 "$body"
}

read_impd_health "$@"
