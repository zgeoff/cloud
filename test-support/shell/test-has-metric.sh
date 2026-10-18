#!/usr/bin/env bash
# Test for has-metric.sh: has_metric finds a line of a metrics page served on loopback, returns 1
# for a pattern no line matches, and returns 1 for a page it cannot read.
#
#   bash test-support/shell/test-has-metric.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/pick-port.sh"
source "$(dirname "${BASH_SOURCE[0]}")/has-metric.sh"

it_finds_a_line_of_the_metrics_page() {
  tree="$(mktemp -d)"
  trap 'kill "${server_pid:-}" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf '%s\n' '# TYPE up gauge' 'up{job="alloy"} 1' > "$tree/www/metrics"

  has_metric "$url" '^up{job="alloy"} 1$'
}

it_returns_1_for_a_pattern_no_line_matches() {
  local status=0
  tree="$(mktemp -d)"
  trap 'kill "${server_pid:-}" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf '%s\n' '# TYPE up gauge' 'up{job="alloy"} 1' > "$tree/www/metrics"

  has_metric "$url" '^up{job="alloy"} 0$' || status=$?

  assert_equals 1 "$status" "has_metric's exit"
}

it_returns_1_for_a_page_it_cannot_read() {
  local status=0

  has_metric 'http://127.0.0.1:1' 'up' || status=$?

  assert_equals 1 "$status" "has_metric's exit"
}

# setup_test <tree>: a file server over <tree>/www on a loopback port
setup_test() {
  local port
  mkdir "$1/www"
  port="$(pick_port)"
  url="http://127.0.0.1:$port"
  python3 -m http.server --bind 127.0.0.1 --directory "$1/www" "$port" > "$1/www.log" 2>&1 &
  server_pid=$!
  wait_for 10 "the file server" curl -fs -o /dev/null "$url/"
}

run_cases
