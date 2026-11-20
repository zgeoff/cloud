#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for start-stub-slow-download.sh: the slow download stand-in serves its body with 200 at the
# speed it was given, answers `Range: bytes=<first>-` with 206 and the bytes from <first> on, and a
# <first> past the end with 416, sends only the headers at a speed of 0, records each GET with its
# range in arrival order, and fails closed on every other request.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'start-stub-slow-download.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true
}

@test "it serves the whole body with 200 at the speed it was given" {
  local seconds
  start_stub_slow_download "$tree/download" 65536 65536

  seconds="$(curl -q --noproxy '*' -sS --max-time 10 -D "$tree/headers" -o "$tree/body" \
    -w '%{time_total}' "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:\|^content-range:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 65536
EOF
  assert_equal "$(stat -c %s "$tree/download/body")" 65536
  cmp "$tree/download/body" "$tree/body"
  # 64 KiB at 64 KiB/s: the stand-in pauses after each of its 16 writes of 4 KiB, 1/16 s each
  awk -v s="$seconds" 'BEGIN { exit !(s >= 0.9) }'
  diff - "$tree/download/requests" <<< 'GET /chrome.zip -'
  refute [ -e "$tree/download/unexpected" ]
  refute [ -L "$tree/download/unexpected" ]
}

@test "it answers a range with 206 and the bytes from its first byte on" {
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

@test "it answers a range past the end with 416" {
  local code
  start_stub_slow_download "$tree/download" 8192 1048576

  code="$(curl -q --noproxy '*' -sS --max-time 10 -H 'Range: bytes=8192-' -D "$tree/headers" \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  assert_equal "$code" 416
  tr -d '\r' < "$tree/headers" | grep -i '^content-length:\|^content-range:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
content-range: bytes */8192
content-length: 0
EOF
  diff /dev/null "$tree/body"
  diff - "$tree/download/requests" <<< 'GET /chrome.zip bytes=8192-'
}

@test "it sends only the headers at a speed of 0" {
  start_stub_slow_download "$tree/download" 8192 0

  run -28 --separate-stderr curl -q --noproxy '*' -sS --max-time 1 -D "$tree/headers" -o "$tree/body" \
    "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip"

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 8192
EOF
  refute [ -e "$tree/body" ]
  refute [ -L "$tree/body" ]
  # the elapsed milliseconds are a measurement, so they are masked
  stderr="$(sed -E 's/after [0-9]+ milliseconds/after <ms> milliseconds/' <<< "$stderr")"
  assert_stderr 'curl: (28) Operation timed out after <ms> milliseconds with 0 out of 8192 bytes received'
}

@test "it fails closed on another method" {
  local code
  start_stub_slow_download "$tree/download" 8192 1048576

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip")"

  assert_equal "$code" 500
  printf '%s' 'stub-slow-download: unexpected POST /chrome.zip' | diff - "$tree/body"
  diff - "$tree/download/unexpected" <<< 'POST /chrome.zip'
  refute [ -e "$tree/download/requests" ]
  refute [ -L "$tree/download/requests" ]
}
