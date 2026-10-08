#!/usr/bin/env bash
# Test for start-stub-resetting-listener.sh: the listener resets each connection after
# reading the request, so real curl fails as it does when a peer drops the connection
# mid-request, and it records each connection. The curl exit code and message are pinned
# on curl 8.22.0.
#
#   bash scripts/test-lib/test-start-stub-resetting-listener.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-resetting-listener.sh"

it_resets_the_connection_so_real_curl_fails_with_exit_56() {
  local status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/listener/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q --noproxy '*' -sS \
    --max-time 10 --data '{"json":{}}' "http://127.0.0.1:$(cat "$tree/listener/port")/rpc/tokens/whoami" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (56) Recv failure: Connection reset by peer'
  diff - "$tree/listener/connections" <<< 'connection'
  [ "$status" = 56 ] || { echo "exit $status, want 56" >&2; exit 1; }
}

it_resets_every_connection_and_records_each() {
  local first=0 second=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/listener/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q --noproxy '*' -sS \
    --max-time 10 "http://127.0.0.1:$(cat "$tree/listener/port")/first" > "$tree/first-out" 2> "$tree/first-err" || first=$?
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q --noproxy '*' -sS \
    --max-time 10 "http://127.0.0.1:$(cat "$tree/listener/port")/second" > "$tree/second-out" 2> "$tree/second-err" || second=$?

  diff - "$tree/listener/connections" << 'LINES'
connection
connection
LINES
  diff /dev/null "$tree/first-out"
  diff /dev/null "$tree/second-out"
  diff - "$tree/first-err" <<< 'curl: (56) Recv failure: Connection reset by peer'
  diff - "$tree/second-err" <<< 'curl: (56) Recv failure: Connection reset by peer'
  [ "$first" = 56 ] || { echo "first exit $first, want 56" >&2; exit 1; }
  [ "$second" = 56 ] || { echo "second exit $second, want 56" >&2; exit 1; }
}

it_records_no_connection_until_one_arrives() {
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/listener/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  ls -A "$tree/listener" > "$tree/files"

  diff - "$tree/files" << 'FILES'
pid
port
FILES
}

# Runtime every case needs: the listener, started in <tree>/listener, and the HOME and
# TMPDIR that curl runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/listener" "$tree/home" "$tree/tmp"
  start_stub_resetting_listener "$tree/listener"
}

run_cases
