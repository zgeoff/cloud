#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for has-metric.sh: has_metric finds a line of a metrics page served on loopback, returns 1
# for a pattern no line matches, and returns 1 for a page it cannot read.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'wait-for.sh'
  load 'pick-port.sh'
  load 'has-metric.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "${server_pid:-}" 2> /dev/null || true
}

# setup_test <tree>: a file server over <tree>/www on a loopback port
setup_test() {
  local port
  mkdir "$1/www"
  port="$(pick_port)"
  url="http://127.0.0.1:$port"
  python3 -m http.server --bind 127.0.0.1 --directory "$1/www" "$port" > "$1/www.log" 2>&1 3>&- &
  # shellcheck disable=SC2034 # teardown reads it
  server_pid=$!
  wait_for 10 "the file server" curl -fs -o /dev/null "$url/"
}

@test "it finds a line of the metrics page" {
  setup_test "$tree"
  printf '%s\n' '# TYPE up gauge' 'up{job="alloy"} 1' > "$tree/www/metrics"

  has_metric "$url" '^up{job="alloy"} 1$'
}

@test "it returns 1 for a pattern no line matches" {
  setup_test "$tree"
  printf '%s\n' '# TYPE up gauge' 'up{job="alloy"} 1' > "$tree/www/metrics"

  run -1 has_metric "$url" '^up{job="alloy"} 0$'
}

@test "it returns 1 for a page it cannot read" {
  run -1 has_metric 'http://127.0.0.1:1' 'up'
}
