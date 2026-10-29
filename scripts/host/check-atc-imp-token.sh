#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-gateway-credentials.ts sends this file on ssh's stdin,
# with the argv that runs imp's CLI in imp-host, IMP_TOKEN and IMP_URL passed through, after the
# directory and impd's port (scripts/imp-cli.ts names the CLI, so this script never does):
#
#   ssh root@geoffcloud bash -s -- <dir> <impd port> podman exec -e IMP_TOKEN -e IMP_URL imp-host <imp's CLI>
#
# It asks impd who <dir>/imp-token is, through the CLI's `token whoami --json` on loopback. The
# token goes from the file into podman's environment, which `podman exec -e IMP_TOKEN` copies into
# the CLI's, so it never enters an argv or returns to the caller: only the CLI's answer returns.
# With IMP_URL set, the CLI uses IMP_TOKEN and no saved host or token file of its own.
#
# atc 2.24.0 reads the whole file and drops one trailing newline (readImpToken); the rest is the
# token. So a file whose token is empty or holds a byte that is not printable, non-space ASCII (a
# second line, a CR, a space, a NUL) exits 121: bad. A path that is not a readable regular file,
# or that cannot be read, exits 120: unchecked, not bad. A token impd refuses exits 122: bad. Any
# other failure exits with the CLI's code, 1 for a refused connection, and stays unchecked. 120 to
# 122 sit above the CLI's codes and below ssh's.
set -euo pipefail
export LC_ALL=C

check_imp_token() {
  local file="$1/imp-token" port="$2" size value status=0
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "usage: check-atc-imp-token.sh <dir> <impd port> <imp CLI argv>..." >&2
    exit 2
  fi
  { test -f "$file" && test -r "$file"; } || exit 120
  size="$(wc -c < "$file")" || exit 120
  value="$(cat "$file" && printf x)" || exit 120
  value="${value%x}"
  # command substitution drops a NUL byte, so a file that held one reads shorter than its size
  test "${#value}" = "$size" || exit 121
  value="${value%$'\n'}"
  [[ "$value" =~ ^[[:graph:]]+$ ]] || exit 121
  # global, so the EXIT trap still reads it after this function returns
  errors="$(mktemp)"
  trap 'rm -f "$errors"' EXIT
  # podman exec without -i leaves stdin alone, which holds the rest of this script
  IMP_TOKEN="$value" IMP_URL="http://127.0.0.1:$port" "$@" token whoami --json 2> "$errors" ||
    status=$?
  # the CLI's one line for impd's 401 (packages/cli/src/run-action.ts in imp's repo at v2.4.1)
  if [ "$status" -ne 0 ] && grep -q '^[^:]*: unauthorized: ' "$errors"; then
    exit 122
  fi
  cat "$errors" >&2
  exit "$status"
}

check_imp_token "$@"
