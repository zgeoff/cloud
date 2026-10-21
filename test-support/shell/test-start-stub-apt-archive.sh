#!/usr/bin/env bash
# Test for start-stub-apt-archive.sh: the Ubuntu archive stand-in serves a file under its root by
# path with 200, answers 404 for a path it does not hold, also for one that climbs out of its root,
# answers a fault's status for the fault's count of GETs and then the file, or for every GET with
# `all`, records each GET with its status and the Host header's name, and fails closed on every
# other method. curl stands in for apt's http method here; the agent image suite drives it with
# the real apt.
#
#   bash test-support/shell/test-start-stub-apt-archive.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the stand-in reads do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/pick-port.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-apt-archive.sh"

it_serves_a_file_under_its_root_and_records_the_get_with_the_host_name() {
  local port code
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  mkdir -p "$tree/archive/root/ubuntu/dists/noble"
  echo 'Suite: noble' > "$tree/archive/root/ubuntu/dists/noble/Release"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -H 'Host: archive.ubuntu.com' -o "$tree/body" -w '%{http_code}' \
    "http://127.0.0.1:$port/ubuntu/dists/noble/Release")"

  assert_equals 200 "$code"
  diff - "$tree/body" <<< 'Suite: noble'
  diff - "$tree/archive/requests" <<< '200 archive.ubuntu.com /ubuntu/dists/noble/Release'
  assert_missing "$tree/archive/unexpected" "the GET was recorded as unexpected"
}

it_answers_404_for_a_path_it_does_not_hold() {
  local port code
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/ubuntu/dists/noble/InRelease")"

  assert_equals 404 "$code"
  diff /dev/null "$tree/body"
  diff - "$tree/archive/requests" <<< '404 127.0.0.1 /ubuntu/dists/noble/InRelease'
}

it_answers_404_for_a_path_that_climbs_out_of_its_root() {
  local port code
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  echo 'outside' > "$tree/archive/outside"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    --path-as-is -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/../outside")"

  assert_equals 404 "$code"
  diff /dev/null "$tree/body"
  diff - "$tree/archive/requests" <<< '404 127.0.0.1 /../outside'
}

it_answers_a_fault_s_status_for_its_count_of_gets_then_the_file() {
  local port first second third
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  mkdir -p "$tree/archive/root/pool"
  echo 'deb' > "$tree/archive/root/pool/stub.deb"
  echo '503 2 /pool/stub.deb' > "$tree/archive/faults"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  first="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  second="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  third="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"

  assert_equals 503 "$first"
  assert_equals 503 "$second"
  assert_equals 200 "$third"
  diff - "$tree/body" <<< 'deb'
  diff - "$tree/archive/requests" << 'EOF'
503 127.0.0.1 /pool/stub.deb
503 127.0.0.1 /pool/stub.deb
200 127.0.0.1 /pool/stub.deb
EOF
}

it_answers_a_fault_s_status_for_every_get_with_all() {
  local port first second
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  mkdir -p "$tree/archive/root/pool"
  echo 'deb' > "$tree/archive/root/pool/stub.deb"
  echo '502 all /pool/stub.deb' > "$tree/archive/faults"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  first="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  second="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"

  assert_equals 502 "$first"
  assert_equals 502 "$second"
  diff - "$tree/archive/requests" << 'EOF'
502 127.0.0.1 /pool/stub.deb
502 127.0.0.1 /pool/stub.deb
EOF
}

it_refuses_another_method_and_records_it_as_unexpected() {
  local port code
  create_case_tree 'kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -X POST -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/ubuntu/dists/noble/Release")"

  assert_equals 500 "$code"
  printf '%s' 'stub-apt-archive: unexpected POST /ubuntu/dists/noble/Release' | diff - "$tree/body"
  diff - "$tree/archive/unexpected" <<< 'POST /ubuntu/dists/noble/Release'
  assert_missing "$tree/archive/requests" "the POST was recorded as a GET"
}

# The stand-in's directory with an empty root, and a home for curl inside the case tree.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/archive/root" "$tree/home"
}

run_cases
