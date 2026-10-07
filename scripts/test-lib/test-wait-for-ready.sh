#!/usr/bin/env bash
# Test for wait-for-ready.sh: wait_for_ready waits for the gateway's /readyz, or fails
# with the container's logs when the deadline passes or the container stops. It needs
# Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it exits.
#
#   bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-wait-for-ready.sh
#   CASE='after a restart' bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-wait-for-ready.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-gateway.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for-ready.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-clock.sh"

# As above: one answered poll from start_gateway before the restart, and one from
# wait_for_ready after it. Every poll that wait_for_ready makes follows the restart.
it_waits_for_readyz_after_a_restart() {
  local gateway_image="$1" backup_image="$2" run="$3" status=0
  name="atc-gw-ready-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"
  start_gateway "$name" "$tree" "$gateway_image"
  docker restart "$name" > /dev/null

  wait_for_ready "$name" 30 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  docker logs "$name" > "$tree/log.out" 2> "$tree/log.err"
  diff - "$tree/log.out" << 'EOF'
atc-gateway: serving https://atc.fixture.invalid/mcp, listening on http://0.0.0.0:8414
atc-gateway: serving https://atc.fixture.invalid/mcp, listening on http://0.0.0.0:8414
EOF
  sed -E 's/ [0-9.]+ms$/ Tms/' "$tree/log.err" > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
GET /readyz 200 Tms
GET /readyz 200 Tms
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The container publishes 8414 but nothing listens there, so /readyz never answers before
# the one-second deadline, which the fake clock (create-stub-clock.sh) reaches at the first
# pause instead of after a real second. Docker keeps no order between a container's stdout
# and stderr lines, so the case compares the log lines after the timeout as a sorted set.
it_fails_wait_for_ready_with_the_containers_logs_when_readyz_never_answers() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-ready-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$backup_image" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exec sleep 300' > /dev/null
  create_stub_clock "$tree"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for_ready "$name" 1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - <(head -n 1 "$tree/err") <<< "timed out after 1s waiting for $name to answer /readyz with 200"
  diff - <(tail -n +2 "$tree/err" | sort) << 'EOF'
a log line on stderr
a log line on stdout
EOF
  diff - "$tree/pauses" <<< 0.05
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The container has exited before the helper starts, so the helper reports it at its
# first poll, with no pause, instead of polling a port that is gone until the 30-second
# deadline.
it_fails_wait_for_ready_with_the_containers_logs_as_soon_as_the_container_stops() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-ready-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$backup_image" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exit 3' > /dev/null
  docker wait "$name" > /dev/null
  create_stub_clock "$tree"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for_ready "$name" 30 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - <(head -n 1 "$tree/err") <<< "$name stopped before it answered /readyz with 200"
  diff - <(tail -n +2 "$tree/err" | sort) << 'EOF'
a log line on stderr
a log line on stdout
EOF
  [ ! -e "$tree/pauses" ] || { echo "wait_for_ready paused before it reported the stop" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Boot data every case that calls it needs: the registry that start_gateway mounts, and a
# state volume owned by the nonroot uid, as fsGroup 65532 leaves the pod's new volume.
# Its chown container is named for the case's trap.
setup_test() {
  local tree="$1" name="$2" backup_image="$3"
  mkdir "$tree/registry"
  # start_gateway mounts it; the gateway exits at boot without it, and serves without
  # reaching its daemon, a dead address
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh -v "$name-state:/s" \
    "$backup_image" -c 'chown 65532:65532 /s'
}

: "${FIXTURE_RUN:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
run_cases "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" "$FIXTURE_RUN"
