#!/usr/bin/env bash
# Test for start-stub-stalled-download.sh: the stalled download stand-in answers a GET with 200, a
# 1 MiB content-length and the first 4 KiB, then sends nothing more, records each GET in arrival
# order, and fails closed on every other request.
#
#   bash test-support/shell/test-start-stub-stalled-download.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-stalled-download.sh"

# setup_test <tree>: the stand-in, listening, with its files in <tree>/download
setup_test() {
  local tree="$1"
  start_stub_stalled_download "$tree/download"
}

it_sends_the_headers_and_the_first_4_kib_then_stalls() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  curl -q --noproxy '*' -sS --max-time 2 -D "$tree/headers" -o "$tree/body" \
    "http://127.0.0.1:$(cat "$tree/download/port")/go.tar.gz" 2> "$tree/err" || status=$?

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 1048576
EOF
  assert_equals 4096 "$(stat -c %s "$tree/body")" "the bytes received"
  # the elapsed milliseconds are a measurement, so they are masked
  sed -E 's/after [0-9]+ milliseconds/after <ms> milliseconds/' "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" <<< 'curl: (28) Operation timed out after <ms> milliseconds with 4096 out of 1048576 bytes received'
  diff - "$tree/download/requests" <<< 'GET /go.tar.gz'
  assert_missing "$tree/download/unexpected" "the GET was recorded as unexpected"
  assert_status 28 "$status"
}

it_records_each_get_in_arrival_order() {
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  curl -q --noproxy '*' -s --max-time 1 -o /dev/null "http://127.0.0.1:$(cat "$tree/download/port")/first" || true
  curl -q --noproxy '*' -s --max-time 1 -o /dev/null "http://127.0.0.1:$(cat "$tree/download/port")/second" || true

  diff - "$tree/download/requests" << 'EOF'
GET /first
GET /second
EOF
}

it_fails_closed_on_another_method() {
  local code
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/download/port")/go.tar.gz")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' 'stub-stalled-download: unexpected POST /go.tar.gz' | diff - "$tree/body"
  diff - "$tree/download/unexpected" <<< 'POST /go.tar.gz'
  assert_missing "$tree/download/requests" "the POST was recorded as a GET"
}

run_cases
