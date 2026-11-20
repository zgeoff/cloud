#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Fixture test for the atc-gateway image (Dockerfile), run locally with Docker. It touches
# no cluster, no tailnet and no cloud account.
#
# It runs the pinned atc-gateway release with the flags and the container security the
# Deployment sets (infra/cluster/build-atc-gateway-spec.ts). What this proves: the image builds
# from a checked binary, runs as nonroot on a read-only root, answers /healthz, /readyz
# and the metadata only on its public Host, adds a client, and keeps its state on the
# volume across a restart. What it does not prove: gateway-to-daemon transport (the
# registry's daemon is a dead address), k3s.
#
# The images come from scripts/src/test-utils/shell/with-fixture-images.sh, which builds them once
# per run under tags carrying a random per-run id, removes them after, and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE. Each case starts its own
# container on its own volume and an ephemeral host port, all named from that id, and
# removes them when it ends. `bun run test:atc-gateway-fixture` runs it after the helper
# tests; alone:
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='foreign Host' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

# a case runs a chown container and boots the gateway, which has 30 seconds to answer readyz
export BATS_TEST_TIMEOUT=120

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
  : "${FIXTURE_RUN:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/start-gateway.sh'
  load '../../scripts/src/test-utils/shell/wait-for-ready.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-image-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # sets RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/images/atc-gateway/versions.env"
}

teardown() {
  stop_timeout_watchdog
  docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true
  docker volume rm -f "$name-state" > /dev/null || true
}

# Boot data every case needs: the registry the gateway reads, whose daemon is a dead
# address (the gateway serves without reaching it), and a state volume owned by the
# nonroot uid, as fsGroup 65532 leaves the pod's new volume. The pinned restic image
# does the chown.
setup_test() {
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  # shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" "$RESTIC_IMAGE" -c 'chown 65532:65532 /s'
}

# start_case_gateway: setup_test, then the gateway, and port set to its published host port
start_case_gateway() {
  setup_test
  start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
}

# request <host> <path>: sets code to the status of a GET of <path> with the Host header <host>,
# and writes the body to <tree>/body
request() {
  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H "Host: $1" \
    "http://127.0.0.1:$port$2")"
}

@test "it answers the protected resource metadata on its public Host" {
  local code port
  start_case_gateway

  request atc.fixture.invalid /.well-known/oauth-protected-resource/mcp

  jq -S . "$tree/body" > "$tree/body.json"
  diff - "$tree/body.json" << 'EOF'
{
  "authorization_servers": [
    "https://atc.fixture.invalid"
  ],
  "bearer_methods_supported": [
    "header"
  ],
  "resource": "https://atc.fixture.invalid/mcp",
  "resource_name": "atc",
  "scopes_supported": [
    "read",
    "message",
    "spawn",
    "kill"
  ]
}
EOF
  assert_equal "$code" 200
}

@test "it answers healthz on its public Host" {
  local code port
  start_case_gateway

  request atc.fixture.invalid /healthz

  [ -f "$tree/body" ]
  diff /dev/null "$tree/body"
  assert_equal "$code" 200
}

@test "it answers readyz on its public Host" {
  local code port
  start_case_gateway

  request atc.fixture.invalid /readyz

  [ -f "$tree/body" ]
  diff /dev/null "$tree/body"
  assert_equal "$code" 200
}

# the kubelet's probe reaches the pod by its IP, so the probe must set Host
@test "it refuses healthz for a foreign Host" {
  local code port
  start_case_gateway

  request 10.42.0.9:8414 /healthz

  [ -f "$tree/body" ]
  diff /dev/null "$tree/body"
  assert_equal "$code" 403
}

@test "it refuses the metadata for a foreign Host" {
  local code port
  start_case_gateway

  request 10.42.0.9:8414 /.well-known/oauth-protected-resource/mcp

  [ -f "$tree/body" ]
  diff /dev/null "$tree/body"
  assert_equal "$code" 403
}

@test "it runs the gateway process as the nonroot uid" {
  setup_test

  start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"

  docker top "$name" -eo uid,gid,comm,pid > "$tree/top"
  awk '{ print $1, $2, $3 }' "$tree/top" > "$tree/processes"
  diff - "$tree/processes" << 'EOF'
UID GID COMMAND
65532 65532 atc-gateway
EOF
}

# The client ID is random, so the case reads it from the output, then diffs the whole
# output with it; an output of another shape yields no ID and fails both checks.
@test "it prints the new clients ID when it adds a client" {
  local client_id
  setup_test
  start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"

  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/out" 2> "$tree/err"

  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' < "$tree/out")"
  [ -n "$client_id" ] || {
    cat "$tree/out" >&2
    echo "no client ID in the add output" >&2
    return 1
  }
  diff - "$tree/out" <<< "Added fixture-client. Its client ID is $client_id"
  diff /dev/null "$tree/err"
}

@test "it keeps a stored client across a restart" {
  local client_id
  setup_test
  start_gateway "$name" "$tree" "$FIXTURE_GATEWAY_IMAGE"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || {
    cat "$tree/added"
    echo "no client ID in the add output" >&2
    return 1
  }

  docker restart "$name" > /dev/null
  wait_for_ready "$name" 30

  docker exec "$name" /usr/local/bin/atc-gateway clients list > "$tree/clients"
  diff - "$tree/clients" <<< "$client_id  fixture-client  https://client.fixture.invalid/callback"
}
