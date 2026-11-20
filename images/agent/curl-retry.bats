#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for the agent image's CURL_RETRY, the curl options that every download in the Dockerfile
# takes: a transfer that stalls after its headers ends with curl's exit 28 and retries, rather than
# holding the build until its timeout. Each case reads CURL_RETRY from the Dockerfile's ARG line and
# runs the real curl with it, as a RUN step does, against the stalled download stand-in from
# scripts/src/test-utils/shell. The case rewrites the values of the options' own --speed-time to 1 and
# --retry to 1, so a stall ends in 1 s and the case waits for one retry rather than five. It adds no
# option, because curl gives --speed-limit a default of 1 byte a second whenever --speed-time is
# set, so an added --speed-time would end the stall without the Dockerfile's options. It runs curl
# under `timeout 30`, so options that never end a stall fail the case with exit 124 instead of
# hanging it.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/start-stub-stalled-download.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  dockerfile="$BATS_TEST_DIRNAME/Dockerfile"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true
}

# setup_test <tree>: the stalled download stand-in, listening, with its files in <tree>/download,
# and the home and temp folders curl runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
  start_stub_stalled_download "$tree/download" 3>&-
}

@test "it retries a transfer that stalls after its headers and then fails with exit 28" {
  local options
  setup_test "$tree"
  options="$(sed -nE 's/^ARG CURL_RETRY="(.*)"$/\1/p' "$dockerfile" |
    sed -E 's/--speed-time [0-9]+/--speed-time 1/; s/--retry [0-9]+/--retry 1/')"

  # shellcheck disable=SC2086 # the options split into words, as ${CURL_RETRY} does in a RUN step
  run -28 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout 30 curl -q --noproxy '*' -fsSL $options -o "$tree/go.tar.gz" \
    "http://127.0.0.1:$(cat "$tree/download/port")/go.tar.gz"

  refute_output
  assert_stderr - << 'EOF'
curl: (28) Operation too slow. Less than 1024 bytes/sec transferred the last 1 seconds
curl: (28) Operation too slow. Less than 1024 bytes/sec transferred the last 1 seconds
EOF
  diff - "$tree/download/requests" << 'EOF'
GET /go.tar.gz
GET /go.tar.gz
EOF
}
