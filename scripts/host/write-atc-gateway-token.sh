#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-gateway-credentials.ts sends this file on ssh's stdin,
# followed by one line that holds the atc daemon's bearer:
#
#   ssh root@geoffcloud bash -s -- <dir>
#
# bash reads its script from a pipe a byte at a time, so the `read` below takes the line after the
# script. The bearer never reaches the host's command line, which Tailscale SSH logs. It lands in
# <dir>/gateway-token, mode 0400, in one rename; a failure leaves no temporary file behind.
set -euo pipefail

write_gateway_token() {
  local dir="$1" value
  umask 077
  # global, so the EXIT trap still reads it after a failure inside this function
  temp="$(mktemp "$dir/.gateway-token.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  IFS= read -r value
  printf '%s\n' "$value" > "$temp"
  unset value
  chmod 0400 "$temp"
  # -T: a directory in the way fails the move instead of taking the file inside it
  mv -T "$temp" "$dir/gateway-token"
  trap - EXIT
}

write_gateway_token "$@"
