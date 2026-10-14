#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-gateway-credentials.ts sends this file on ssh's stdin:
#
#   ssh root@geoffcloud bash -s -- <dir> <impd port>
#
# It asks impd who <dir>/imp-token is, with impd's tokens.whoami on loopback. The token goes from
# the file to curl's stdin, never into argv or back to the caller: only impd's answer returns,
# then a line with its HTTP status.
#
# atc 2.24.0 reads the whole file and drops one trailing newline (readImpToken); the rest is the
# token. So a file whose token is empty or holds a byte that is not printable, non-space ASCII (a
# second line, a CR, a space, a NUL) exits 121: bad. A path that is not a readable regular file,
# or that cannot be read, exits 120: unchecked, not bad. 120 and 121 sit above curl's codes and
# below ssh's, so a curl failure, such as exit 7 for a refused connection, stays unchecked too.
# curl runs with -q first (no .curlrc), --noproxy '*' and no proxy variables, so no config on the
# host can trace the request or route it off loopback.
set -euo pipefail
export LC_ALL=C

check_imp_token() {
  local file="$1/imp-token" port="$2" size value
  { test -f "$file" && test -r "$file"; } || exit 120
  size="$(wc -c < "$file")" || exit 120
  value="$(cat "$file" && printf x)" || exit 120
  value="${value%x}"
  # command substitution drops a NUL byte, so a file that held one reads shorter than its size
  test "${#value}" = "$size" || exit 121
  value="${value%$'\n'}"
  [[ "$value" =~ ^[[:graph:]]+$ ]] || exit 121
  printf 'Authorization: Bearer %s\n' "$value" |
    env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      -u no_proxy -u NO_PROXY \
      curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json' \
      --data '{"json":{}}' -w '\n%{http_code}' "http://127.0.0.1:$port/rpc/tokens/whoami"
}

check_imp_token "$@"
