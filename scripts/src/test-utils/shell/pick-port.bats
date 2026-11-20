#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for pick-port.sh: pick_port prints one port number, and a server can listen on it on
# 127.0.0.1 once the helper returns.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'pick-port.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
}

teardown() {
  stop_timeout_watchdog
}

@test "it prints one ephemeral port number" {
  local port
  port="$(pick_port)"

  [[ "$port" =~ ^[0-9]+$ ]]
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
}

@test "it prints a port a server can then listen on" {
  local port
  port="$(pick_port)"

  python3 -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); s.close()' "$port"
}
