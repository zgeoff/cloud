#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-gateway-credentials.ts sends this file on ssh's stdin:
#
#   ssh root@geoffcloud bash -s -- <dir>
#
# It mints impd's token atc-cloud (scope manage, imps harness-*, may grant glm) straight into
# <dir>/imp-token, mode 0400, in one rename, so the token never leaves the host. A mint that
# prints anything but one line, or fails, leaves no file behind.
set -euo pipefail

mint_atc_imp_token() {
  local dir="$1"
  umask 077
  # global, so the EXIT trap still reads it after a failure inside this function
  temp="$(mktemp "$dir/.imp-token.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  # docker exec without -i leaves stdin alone, which holds the rest of this script
  docker exec imp-host impz token new atc-cloud --scope manage --imps 'harness-*' \
    --grantable glm > "$temp"
  test "$(wc -l < "$temp")" -eq 1
  chmod 0400 "$temp"
  mv -T "$temp" "$dir/imp-token"
  trap - EXIT
}

mint_atc_imp_token "$@"
