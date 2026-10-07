#!/usr/bin/env bash
# Test for start-gateway.sh: start_gateway runs the gateway as the Deployment does and
# returns once /readyz answers 200. It needs Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it exits.
#
#   bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-start-gateway.sh
#   CASE='readyz' bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-start-gateway.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-gateway.sh"

it_starts_the_gateway_with_the_deployments_container_security_env_and_args() {
  local gateway_image="$1" backup_image="$2" run="$3"
  name="atc-gw-start-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  start_gateway "$name" "$tree" "$gateway_image" > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
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
it_returns_from_start_gateway_only_once_readyz_answers_200() {
  local gateway_image="$1" backup_image="$2" run="$3" status=0
  name="atc-gw-start-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  start_gateway "$name" "$tree" "$gateway_image" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  docker logs "$name" > "$tree/log.out" 2> "$tree/log.err"
  diff - "$tree/log.out" <<< 'atc-gateway: serving https://atc.fixture.invalid/mcp, listening on http://0.0.0.0:8414'
  sed -E 's/ [0-9.]+ms$/ Tms/' "$tree/log.err" > "$tree/requests"
  diff - "$tree/requests" <<< 'GET /readyz 200 Tms'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
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
