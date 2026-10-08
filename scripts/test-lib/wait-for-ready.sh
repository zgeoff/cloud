# shellcheck shell=bash
# wait_for_ready <name> <seconds>: polls the gateway container <name> on /readyz with its
# public Host (atc.fixture.invalid), through the loopback port published for 8414, until
# it answers 200, for at most <seconds>. It stops polling as soon as the container is not
# running. When the container stops first it prints "<name> stopped before it answered
# /readyz with 200", and past the deadline it prints wait_for's timeout; either way it
# then prints the container's last 20 log lines to stderr and returns 1.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

wait_for_ready() {
  local name="$1" seconds="$2"
  # one poll: true once the gateway answers 200, or once there is no running container to
  # wait for
  # shellcheck disable=SC2016 # expanded by the poll's own bash
  local poll='
    [ "$(docker inspect -f "{{.State.Running}}" "$1" 2> /dev/null)" = true ] || exit 0
    port="$(docker port "$1" 8414/tcp 2> /dev/null)" || exit 1
    [ "$(curl -q --noproxy "*" -s -o /dev/null -w "%{http_code}" -H "Host: atc.fixture.invalid" \
      "http://127.0.0.1:${port##*:}/readyz")" = 200 ]'
  if ! wait_for "$seconds" "$name to answer /readyz with 200" bash -c "$poll" wait-for-ready "$name"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2> /dev/null)" != true ]; then
    echo "$name stopped before it answered /readyz with 200" >&2
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
}
