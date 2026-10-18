#!/usr/bin/env bash
# Test for pick-port.sh: pick_port prints one port number, and a server can listen on it on
# 127.0.0.1 once the helper returns.
#
#   bash test-support/shell/test-pick-port.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/pick-port.sh"

it_prints_one_ephemeral_port_number() {
  local port
  port="$(pick_port)"

  [[ "$port" =~ ^[0-9]+$ ]] || {
    echo "printed $port, want a number" >&2
    exit 1
  }
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || {
    echo "port $port, want 1024 to 65535" >&2
    exit 1
  }
}

it_prints_a_port_a_server_can_then_listen_on() {
  local port
  port="$(pick_port)"

  python3 -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); s.close()' "$port"
}

run_cases
