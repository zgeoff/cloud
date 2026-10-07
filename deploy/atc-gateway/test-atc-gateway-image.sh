#!/usr/bin/env bash
# Fixture test for the atc-gateway image (Dockerfile), run locally with Docker. It touches
# no cluster, no tailnet and no cloud account.
#
# It runs the pinned atc-gateway release with the flags and the container security the
# Deployment sets (infra/build-atc-gateway-spec.ts). What this proves: the image builds
# from a checked binary, runs as nonroot on a read-only root, answers /healthz, /readyz
# and the metadata only on its public Host, adds a client, and keeps its state on the
# volume across a restart. What it does not prove: gateway-to-daemon transport (the
# registry's daemon is a dead address), k3s.
#
# The images come from scripts/test-lib/with-fixture-images.sh, which builds them once
# per run under tags carrying a random per-run id, removes them after, and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE. Each case starts its own
# container on its own volume and an ephemeral host port, all named from that id, and
# removes them when it exits. `bun run test:atc-gateway-fixture` runs it after the helper
# tests; alone:
#
#   bash scripts/test-lib/with-fixture-images.sh bash deploy/atc-gateway/test-atc-gateway-image.sh
#   CASE='foreign Host' bash scripts/test-lib/with-fixture-images.sh bash deploy/atc-gateway/test-atc-gateway-image.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/test-lib/start-gateway.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/test-lib/wait-for-ready.sh"

it_answers_the_protected_resource_metadata_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

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
  "scopes_supported": [
    "read",
    "message",
    "spawn",
    "kill"
  ]
}
EOF
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_healthz_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/healthz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_readyz_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/readyz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

# the kubelet's probe reaches the pod by its IP, so the probe must set Host
it_refuses_healthz_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/healthz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_refuses_the_metadata_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_runs_the_gateway_process_as_the_nonroot_uid() {
  local gateway_image="$1"
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"

  start_gateway "$name" "$tree" "$gateway_image"

  docker top "$name" -eo uid,gid,comm,pid > "$tree/top"
  awk '{ print $1, $2, $3 }' "$tree/top" > "$tree/processes"
  diff - "$tree/processes" << 'EOF'
UID GID COMMAND
65532 65532 atc-gateway
EOF
}

# The client ID is random, so the case reads it from the output, then diffs the whole
# output with it; an output of another shape yields no ID and fails both checks.
it_prints_the_new_clients_ID_when_it_adds_a_client() {
  local gateway_image="$1" client_id status=0
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"

  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added" 2> "$tree/err" || status=$?

  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }
  diff - "$tree/added" <<< "Added fixture-client. Its client ID is $client_id"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_keeps_a_stored_client_across_a_restart() {
  local gateway_image="$1" client_id
  name="atc-gw-image-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }

  docker restart "$name" > /dev/null
  wait_for_ready "$name" 30

  docker exec "$name" /usr/local/bin/atc-gateway clients list > "$tree/clients"
  diff - "$tree/clients" <<< "$client_id  fixture-client  https://client.fixture.invalid/callback"
}

# Boot data every case needs: the registry the gateway reads, whose daemon is a dead
# address (the gateway serves without reaching it), and a state volume owned by the
# nonroot uid, as fsGroup 65532 leaves the pod's new volume.
setup_test() {
  local tree="$1" name="$2" restic_image="$3"
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" "$restic_image" -c 'chown 65532:65532 /s'
}

# Boot data every case needs: the pinned restic image that setup_test chowns the volumes
# with, and the images and the run id that with-fixture-images.sh provides.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# sets RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"
: "${FIXTURE_RUN:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
# shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
run_cases "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" "$RESTIC_IMAGE" "$FIXTURE_RUN"
