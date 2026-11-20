#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Test for wait-for-ready.sh: wait_for_ready waits for the gateway's /readyz, or fails
# with the container's logs when the deadline passes or the container stops. It needs
# Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it ends.
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='after a restart' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

# the gateway boots and answers readyz within 30 seconds, and a case also runs a chown container
export BATS_TEST_TIMEOUT=120

setup_file() {
  load '../bats/setup'
  : "${FIXTURE_RUN:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
}

setup() {
  load '../bats/setup'
  load 'start-gateway.sh'
  load 'wait-for-ready.sh'
  load 'create-stub-clock.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-ready-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
}

teardown() {
  stop_timeout_watchdog
  docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true
  docker volume rm -f "$name-state" > /dev/null || true
}

# Boot data every case that calls it needs: the registry that start_gateway mounts, and a
# state volume owned by the nonroot uid, as fsGroup 65532 leaves the pod's new volume.
# Its chown container is named for the case's teardown.
setup_test() {
  mkdir "$tree/registry"
  # start_gateway mounts it; the gateway exits at boot without it, and serves without
  # reaching its daemon, a dead address
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh -v "$name-state:/s" \
    "$FIXTURE_BACKUP_IMAGE" -c 'chown 65532:65532 /s'
}

# As in start-gateway.bats: one answered poll from start_gateway before the restart, and one from
# wait_for_ready after it. Every poll that wait_for_ready makes follows the restart.
@test "it waits for readyz after a restart" {
  setup_test
  start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"
  docker restart "$name" > /dev/null

  run -0 --separate-stderr wait_for_ready "$name" 30

  refute_output
  refute_stderr
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
}

# The container publishes 8414 but nothing listens there, so /readyz never answers before
# the one-second deadline, which the fake clock (create-stub-clock.sh) reaches at the first
# pause instead of after a real second. Docker keeps no order between a container's stdout
# and stderr lines, so the case compares the log lines after the timeout as a sorted set.
@test "it fails wait for ready with the containers logs when readyz never answers" {
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$FIXTURE_BACKUP_IMAGE" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exec sleep 300' > /dev/null
  create_stub_clock "$tree"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -1 --separate-stderr wait_for_ready "$name" 1

  refute_output
  head -n 1 <<< "$stderr" > "$tree/err-first"
  tail -n +2 <<< "$stderr" | sort > "$tree/err-logs"
  diff - "$tree/err-first" <<< "timed out after 1s waiting for $name to answer /readyz with 200"
  diff - "$tree/err-logs" << 'EOF'
a log line on stderr
a log line on stdout
EOF
  diff - "$tree/pauses" <<< 0.05
}

# The container has exited before the helper starts, so the helper reports it at its
# first poll, with no pause, instead of polling a port that is gone until the 30-second
# deadline.
@test "it fails wait for ready with the containers logs as soon as the container stops" {
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$FIXTURE_BACKUP_IMAGE" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exit 3' > /dev/null
  docker wait "$name" > /dev/null
  create_stub_clock "$tree"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -1 --separate-stderr wait_for_ready "$name" 30

  refute_output
  head -n 1 <<< "$stderr" > "$tree/err-first"
  tail -n +2 <<< "$stderr" | sort > "$tree/err-logs"
  diff - "$tree/err-first" <<< "$name stopped before it answered /readyz with 200"
  diff - "$tree/err-logs" << 'EOF'
a log line on stderr
a log line on stdout
EOF
  # wait_for_ready reported the stop without a pause
  refute [ -e "$tree/pauses" ]
  refute [ -L "$tree/pauses" ]
}
