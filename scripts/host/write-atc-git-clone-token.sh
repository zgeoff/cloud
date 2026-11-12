#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-git-clone-token.ts sends this file on ssh's stdin,
# followed by one line that holds the GitHub clone token:
#
#   ssh root@geoffcloud bash -s -- <dir>
#
# bash reads its script from a pipe a byte at a time, so the `read` below takes the line after the
# script. The token never reaches the host's command line, which Tailscale SSH logs. It lands in
# <dir>/git-clone-token, mode 0400, in one rename; a failure leaves no temporary file behind.
set -euo pipefail

write_git_clone_token() {
  local dir="$1" value
  umask 077
  # global, so the EXIT trap still reads it after a failure inside this function
  temp="$(mktemp "$dir/.git-clone-token.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  IFS= read -r value
  printf '%s\n' "$value" > "$temp"
  unset value
  chmod 0400 "$temp"
  # -T: a directory in the way fails the move instead of taking the file inside it
  mv -T "$temp" "$dir/git-clone-token"
  trap - EXIT
}

write_git_clone_token "$@"
