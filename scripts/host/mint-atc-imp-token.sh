#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-gateway-credentials.ts sends this file on ssh's stdin,
# with the argv that runs imp's CLI in imp-host after the directory (scripts/imp-cli.ts names the
# CLI, so this script never does):
#
#   ssh root@geoffcloud bash -s -- <dir> docker exec imp-host <imp's CLI>
#
# It mints impd's token atc-cloud (scope manage, imps harness-*, may grant glm and the secrets of
# the daemon's auth profiles in nixos/hosts/geoffcloud/configuration.nix) straight into
# <dir>/imp-token, mode 0400, in one rename, so the token never leaves the host. A mint that
# prints anything but one line, or fails, leaves no file behind. The CLI prints the token alone
# without --json, which is the form the file holds.
set -euo pipefail

mint_atc_imp_token() {
  local dir="$1"
  shift
  if [ "$#" -eq 0 ]; then
    echo "usage: mint-atc-imp-token.sh <dir> <imp CLI argv>..." >&2
    exit 2
  fi
  umask 077
  # global, so the EXIT trap still reads it after a failure inside this function
  temp="$(mktemp "$dir/.imp-token.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  # docker exec without -i leaves stdin alone, which holds the rest of this script
  "$@" token new atc-cloud --scope manage --imps 'harness-*' \
    --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect > "$temp"
  test "$(wc -l < "$temp")" -eq 1
  chmod 0400 "$temp"
  mv -T "$temp" "$dir/imp-token"
  trap - EXIT
}

mint_atc_imp_token "$@"
