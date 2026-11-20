#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Test for start-gateway.sh: start_gateway runs the gateway as the Deployment does and
# returns once /readyz answers 200. It needs Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it ends.
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='readyz' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

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
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-start-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
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

# One docker inspect of the started container, projected to the configuration the
# Deployment sets, is one result: its options, security, env and args come together.
@test "it starts the gateway container with the configuration the deployment sets" {
  setup_test

  run -0 --separate-stderr start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"

  refute_output
  refute_stderr
  # docker keeps no order in the binds or the env it reports, so both are sorted
  docker inspect "$name" | jq -S '.[0] | {
    ReadonlyRootfs: .HostConfig.ReadonlyRootfs, SecurityOpt: .HostConfig.SecurityOpt,
    CapDrop: .HostConfig.CapDrop, Tmpfs: .HostConfig.Tmpfs, Binds: (.HostConfig.Binds | sort),
    PortBindings: .HostConfig.PortBindings, Cmd: .Config.Cmd,
    Env: ([.Config.Env[] | select(startswith("ATC_"))] | sort)}' > "$tree/config"
  diff - "$tree/config" << EOF
{
  "Binds": [
    "$tree/registry:/etc/atc-gateway:ro",
    "$name-state:/home/nonroot/.local/state/atc"
  ],
  "CapDrop": [
    "ALL"
  ],
  "Cmd": [
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    "8414",
    "--public-url",
    "https://atc.fixture.invalid",
    "--registry",
    "/etc/atc-gateway/registry.json",
    "--state-dir",
    "/home/nonroot/.local/state/atc"
  ],
  "Env": [
    "ATC_GATEWAY_STATE_DIR=/home/nonroot/.local/state/atc",
    "ATC_GATEWAY_TOKEN_GEOFFCLOUD=fixture-only"
  ],
  "PortBindings": {
    "8414/tcp": [
      {
        "HostIp": "127.0.0.1",
        "HostPort": ""
      }
    ]
  },
  "ReadonlyRootfs": true,
  "SecurityOpt": [
    "no-new-privileges"
  ],
  "Tmpfs": {
    "/home/nonroot/.config": "uid=65532,gid=65532",
    "/run/atc": "uid=65532,gid=65532",
    "/tmp": "exec"
  }
}
EOF
}

# The gateway logs each request it answers to stderr and its boot line to stdout; a poll
# made before it listens is refused and leaves no line. Read before the case sends any
# request of its own, the log holds exactly the helper's one answered poll, a 200.
@test "it returns from start gateway only once readyz answers 200" {
  setup_test

  run -0 --separate-stderr start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"

  refute_output
  refute_stderr
  docker logs "$name" > "$tree/log.out" 2> "$tree/log.err"
  diff - "$tree/log.out" <<< 'atc-gateway: serving https://atc.fixture.invalid/mcp, listening on http://0.0.0.0:8414'
  sed -E 's/ [0-9.]+ms$/ Tms/' "$tree/log.err" > "$tree/requests"
  diff - "$tree/requests" <<< 'GET /readyz 200 Tms'
}
