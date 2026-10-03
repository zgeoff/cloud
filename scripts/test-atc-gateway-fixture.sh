#!/usr/bin/env bash
# Fixture test for the atc-gateway package, run locally with Docker. It touches no
# cluster, no tailnet and no cloud account.
#
# It runs the pinned atc-gateway release with the flags the Deployment passes. What this
# proves: the image builds from a checked binary, runs as nonroot on a read-only root,
# answers /healthz, /readyz and the metadata only on its public Host, keeps its state on
# the volume across a restart, and that state survives a backup, a wipe and a restore.
# What it does not prove: gateway-to-daemon transport (the registry's daemon is a dead
# address), R2, k3s.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"

public_host=atc.fixture.invalid
port=18414
state_dir=/home/nonroot/.local/state/atc
run_id="atc-gw-fixture-$$"
work="$(mktemp -d)"
failures=0

teardown() {
  docker rm -f "$run_id" > /dev/null 2>&1 || true
  docker volume rm -f "$run_id-state" "$run_id-repo" > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap teardown EXIT

print_check() {
  printf '%-5s %s\n' "$1" "$2"
  if [ "$1" = FAIL ]; then failures=$((failures + 1)); fi
}

expect() {
  if [ "$2" = "$3" ]; then print_check ok "$1 ($3)"; else print_check FAIL "$1: got $3, want $2"; fi
}

start_gateway() {
  docker run -d --name "$run_id" --read-only --tmpfs /run/atc:uid=65532,gid=65532 --tmpfs /tmp:exec --tmpfs /home/nonroot/.config:uid=65532,gid=65532 \
    -v "$run_id-state:$state_dir" -v "$work/registry:/etc/atc-gateway:ro" -p "127.0.0.1:$port:8414" \
    -e ATC_GATEWAY_TOKEN_GEOFFCLOUD=fixture-only -e ATC_GATEWAY_STATE_DIR="$state_dir" \
    atc-gateway:fixture serve --host 0.0.0.0 --port 8414 --public-url "https://$public_host" \
    --registry /etc/atc-gateway/registry.json --state-dir "$state_dir" > /dev/null
  for _ in $(seq 1 30); do
    [ "$(read_status "$public_host" /readyz)" = 200 ] && return 0
    sleep 1
  done
  docker logs "$run_id" 2>&1 | tail -20 >&2
  return 1
}

read_status() {
  curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" \
    "http://127.0.0.1:$port${2:-/.well-known/oauth-protected-resource/mcp}"
}

run_backup() {
  docker run --rm -v "$run_id-state:/state" -v "$run_id-repo:/repo" \
    -e STATE_DIR=/state -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    atc-gateway-backup:fixture "$@"
}

count_clients() {
  docker exec "$run_id" /usr/local/bin/atc-gateway clients list 2>/dev/null | grep -c fixture-client || true
}

echo "== build"
"$repo/scripts/fetch-atc-release.sh" "$work/context" > /dev/null
cp "$repo/deploy/atc-gateway/Dockerfile" "$work/context/"
docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t atc-gateway:fixture "$work/context" > /dev/null
docker build -q --build-arg "RESTIC_IMAGE=$RESTIC_IMAGE" -t atc-gateway-backup:fixture \
  "$repo/deploy/atc-gateway/backup" > /dev/null
print_check ok "images build from the pinned, checked binary and pinned bases"

echo "== serve"
# the registry's daemon is a dead address: the gateway serves without reaching it
mkdir -p "$work/registry"
printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
  > "$work/registry/registry.json"
chmod -R a+rX "$work/registry"
docker volume create "$run_id-state" > /dev/null
# the volume is root-owned when new; the pod gets the same from fsGroup 65532
docker run --rm --user 0 --entrypoint /bin/sh -v "$run_id-state:/s" "$RESTIC_IMAGE" \
  -c 'chown 65532:65532 /s' > /dev/null
start_gateway
expect "metadata with the public Host" 200 "$(read_status "$public_host")"
expect "/healthz with the public Host" 200 "$(read_status "$public_host" /healthz)"
expect "/readyz with the public Host" 200 "$(read_status "$public_host" /readyz)"
expect "/healthz with a foreign Host (the probe must set Host)" 403 "$(read_status "10.42.0.9:8414" /healthz)"
expect "metadata with a foreign Host" 403 "$(read_status "10.42.0.9:8414")"
expect "runs as the nonroot user" nonroot "$(docker inspect -f '{{.Config.User}}' "$run_id")"

echo "== state"
docker exec "$run_id" /usr/local/bin/atc-gateway clients add fixture-client \
  --redirect-uri https://client.fixture.invalid/callback > /dev/null
expect "an OAuth client is stored" 1 "$(count_clients)"
docker restart "$run_id" > /dev/null
for _ in $(seq 1 30); do [ "$(read_status "$public_host" /readyz)" = 200 ] && break; sleep 1; done
expect "the client survives a restart (state is on the volume)" 1 "$(count_clients)"

echo "== backup and restore"
docker volume create "$run_id-repo" > /dev/null
run_backup backup > /dev/null 2>&1 && print_check ok "backup of the live databases" || print_check FAIL "backup"
docker stop "$run_id" > /dev/null
docker run --rm --user 0 --entrypoint /bin/sh -v "$run_id-state:/s" "$RESTIC_IMAGE" -c 'rm -f /s/*.db*'
docker rm "$run_id" > /dev/null
run_backup restore > /dev/null 2>&1 && print_check ok "restore into the wiped volume" || print_check FAIL "restore"
docker run --rm --user 0 --entrypoint /bin/sh -v "$run_id-state:/s" "$RESTIC_IMAGE" \
  -c 'chown -R 65532:65532 /s' > /dev/null
start_gateway
expect "the client is back after the restore" 1 "$(count_clients)"

echo "== $failures failed"
exit "$failures"
