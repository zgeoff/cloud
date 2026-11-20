#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for start-stub-apt-archive.sh: the Ubuntu archive stand-in serves a file under its root by
# path with 200, answers 404 for a path it does not hold, also for one that climbs out of its root,
# answers a fault's status for the fault's count of GETs and then the file, or for every GET with
# `all`, records each GET with its status and the Host header's name, and fails closed on every
# other method. curl stands in for apt's http method here; the agent image suite drives it with
# the real apt.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'pick-port.sh'
  load 'start-stub-apt-archive.sh'
  # fixed, so the files the stand-in reads do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/archive/pid" 2> /dev/null)" 2> /dev/null || true
}

# The stand-in's directory with an empty root, and a home for curl inside the case tree.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/archive/root" "$tree/home"
}

@test "it serves a file under its root and records the get with the host name" {
  local port code
  setup_test "$tree"
  mkdir -p "$tree/archive/root/ubuntu/dists/noble"
  echo 'Suite: noble' > "$tree/archive/root/ubuntu/dists/noble/Release"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -H 'Host: archive.ubuntu.com' -o "$tree/body" -w '%{http_code}' \
    "http://127.0.0.1:$port/ubuntu/dists/noble/Release")"

  assert_equal "$code" 200
  diff - "$tree/body" <<< 'Suite: noble'
  diff - "$tree/archive/requests" <<< '200 archive.ubuntu.com /ubuntu/dists/noble/Release'
  refute [ -e "$tree/archive/unexpected" ]
  refute [ -L "$tree/archive/unexpected" ]
}

@test "it answers 404 for a path it does not hold" {
  local port code
  setup_test "$tree"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/ubuntu/dists/noble/InRelease")"

  assert_equal "$code" 404
  diff /dev/null "$tree/body"
  diff - "$tree/archive/requests" <<< '404 127.0.0.1 /ubuntu/dists/noble/InRelease'
}

@test "it answers 404 for a path that climbs out of its root" {
  local port code
  setup_test "$tree"
  echo 'outside' > "$tree/archive/outside"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    --path-as-is -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/../outside")"

  assert_equal "$code" 404
  diff /dev/null "$tree/body"
  diff - "$tree/archive/requests" <<< '404 127.0.0.1 /../outside'
}

@test "it answers a fault s status for its count of gets then the file" {
  local port first second third
  setup_test "$tree"
  mkdir -p "$tree/archive/root/pool"
  echo 'deb' > "$tree/archive/root/pool/stub.deb"
  echo '503 2 /pool/stub.deb' > "$tree/archive/faults"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  first="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  second="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  third="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"

  assert_equal "$first" 503
  assert_equal "$second" 503
  assert_equal "$third" 200
  diff - "$tree/body" <<< 'deb'
  diff - "$tree/archive/requests" << 'EOF'
503 127.0.0.1 /pool/stub.deb
503 127.0.0.1 /pool/stub.deb
200 127.0.0.1 /pool/stub.deb
EOF
}

@test "it answers a fault s status for every get with all" {
  local port first second
  setup_test "$tree"
  mkdir -p "$tree/archive/root/pool"
  echo 'deb' > "$tree/archive/root/pool/stub.deb"
  echo '502 all /pool/stub.deb' > "$tree/archive/faults"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  first="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"
  second="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/pool/stub.deb")"

  assert_equal "$first" 502
  assert_equal "$second" 502
  diff - "$tree/archive/requests" << 'EOF'
502 127.0.0.1 /pool/stub.deb
502 127.0.0.1 /pool/stub.deb
EOF
}

@test "it refuses another method and records it as unexpected" {
  local port code
  setup_test "$tree"
  port="$(pick_port)"
  start_stub_apt_archive "$tree/archive" "$port" 3>&-

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" curl -q --noproxy '*' -sS --max-time 5 \
    -X POST -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$port/ubuntu/dists/noble/Release")"

  assert_equal "$code" 500
  printf '%s' 'stub-apt-archive: unexpected POST /ubuntu/dists/noble/Release' | diff - "$tree/body"
  diff - "$tree/archive/unexpected" <<< 'POST /ubuntu/dists/noble/Release'
  refute [ -e "$tree/archive/requests" ]
  refute [ -L "$tree/archive/requests" ]
}
