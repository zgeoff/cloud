#!/usr/bin/env bash
# Test for start-stub-slow-download.sh: the slow download stand-in serves its body with 200 at the
# speed it was given, answers `Range: bytes=<first>-` with 206 and the bytes from <first> on, and a
# <first> past the end with 416, sends only the headers at a speed of 0, records each GET with its
# range in arrival order, and fails closed on every other request.
#
#   bash test-support/shell/test-start-stub-slow-download.sh
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
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-slow-download.sh"

it_serves_the_whole_body_with_200_at_the_speed_it_was_given() {
  local seconds
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  start_stub_slow_download "$tree/download" 65536 65536

  seconds="$(curl -q --noproxy '*' -sS --max-time 10 -D "$tree/headers" -o "$tree/body" \
    -w '%{time_total}' "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:\|^content-range:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 65536
EOF
  assert_equals 65536 "$(stat -c %s "$tree/download/body")" "the size of the body it serves"
  cmp "$tree/download/body" "$tree/body"
  # 64 KiB at 64 KiB/s: the stand-in pauses after each of its 16 writes of 4 KiB, 1/16 s each
  awk -v s="$seconds" 'BEGIN { exit !(s >= 0.9) }'
  diff - "$tree/download/requests" <<< 'GET /chrome.zip -'
  assert_missing "$tree/download/unexpected" "the GET was recorded as unexpected"
}

it_answers_a_range_with_206_and_the_bytes_from_its_first_byte_on() {
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  start_stub_slow_download "$tree/download" 8192 1048576

  curl -q --noproxy '*' -sS --max-time 10 -H 'Range: bytes=5000-' -D "$tree/headers" \
    -o "$tree/body" "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip"

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:\|^content-range:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 206 Partial Content
content-range: bytes 5000-8191/8192
content-length: 3192
EOF
  tail -c +5001 "$tree/download/body" | cmp - "$tree/body"
  diff - "$tree/download/requests" <<< 'GET /chrome.zip bytes=5000-'
}

it_answers_a_range_past_the_end_with_416() {
  local code
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  start_stub_slow_download "$tree/download" 8192 1048576

  code="$(curl -q --noproxy '*' -sS --max-time 10 -H 'Range: bytes=8192-' -D "$tree/headers" \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  assert_equals 416 "$code" "the HTTP status"
  tr -d '\r' < "$tree/headers" | grep -i '^content-length:\|^content-range:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
content-range: bytes */8192
content-length: 0
EOF
  diff /dev/null "$tree/body"
  diff - "$tree/download/requests" <<< 'GET /chrome.zip bytes=8192-'
}

it_sends_only_the_headers_at_a_speed_of_0() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  start_stub_slow_download "$tree/download" 8192 0

  curl -q --noproxy '*' -sS --max-time 1 -D "$tree/headers" -o "$tree/body" \
    "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip" 2> "$tree/err" || status=$?

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 8192
EOF
  assert_missing "$tree/body" "a body byte made curl write the file"
  # the elapsed milliseconds are a measurement, so they are masked
  sed -E 's/after [0-9]+ milliseconds/after <ms> milliseconds/' "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" <<< 'curl: (28) Operation timed out after <ms> milliseconds with 0 out of 8192 bytes received'
  assert_status 28 "$status"
}

it_fails_closed_on_another_method() {
  local code
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  start_stub_slow_download "$tree/download" 8192 1048576

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' 'stub-slow-download: unexpected POST /chrome.zip' | diff - "$tree/body"
  diff - "$tree/download/unexpected" <<< 'POST /chrome.zip'
  assert_missing "$tree/download/requests" "the POST was recorded as a GET"
}

run_cases
