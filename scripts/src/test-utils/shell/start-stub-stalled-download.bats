#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for start-stub-stalled-download.sh: the stalled download stand-in answers a GET with 200, a
# 1 MiB content-length and the first 4 KiB, then sends nothing more, records each GET in arrival
# order, and fails closed on every other request.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'start-stub-stalled-download.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true
}

# setup_test <tree>: the stand-in, listening, with its files in <tree>/download
setup_test() {
  local tree="$1"
  start_stub_stalled_download "$tree/download" 3>&-
}

@test "it sends the headers and the first 4 kib then stalls" {
  setup_test "$tree"

  run -28 --separate-stderr curl -q --noproxy '*' -sS --max-time 2 -D "$tree/headers" -o "$tree/body" \
    "http://127.0.0.1:$(cat "$tree/download/port")/go.tar.gz"

  tr -d '\r' < "$tree/headers" | grep -i '^HTTP/\|^content-length:' > "$tree/head-lines"
  diff - "$tree/head-lines" << 'EOF'
HTTP/1.0 200 OK
content-length: 1048576
EOF
  assert_equal "$(stat -c %s "$tree/body")" 4096
  # the elapsed milliseconds are a measurement, so they are masked
  stderr="$(sed -E 's/after [0-9]+ milliseconds/after <ms> milliseconds/' <<< "$stderr")"
  assert_stderr 'curl: (28) Operation timed out after <ms> milliseconds with 4096 out of 1048576 bytes received'
  diff - "$tree/download/requests" <<< 'GET /go.tar.gz'
  refute [ -e "$tree/download/unexpected" ]
  refute [ -L "$tree/download/unexpected" ]
}

@test "it records each get in arrival order" {
  setup_test "$tree"

  curl -q --noproxy '*' -s --max-time 1 -o /dev/null "http://127.0.0.1:$(cat "$tree/download/port")/first" || true
  curl -q --noproxy '*' -s --max-time 1 -o /dev/null "http://127.0.0.1:$(cat "$tree/download/port")/second" || true

  diff - "$tree/download/requests" << 'EOF'
GET /first
GET /second
EOF
}

@test "it fails closed on another method" {
  local code
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/download/port")/go.tar.gz")"

  assert_equal "$code" 500
  printf '%s' 'stub-stalled-download: unexpected POST /go.tar.gz' | diff - "$tree/body"
  diff - "$tree/download/unexpected" <<< 'POST /go.tar.gz'
  refute [ -e "$tree/download/requests" ]
  refute [ -L "$tree/download/requests" ]
}
