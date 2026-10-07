#!/usr/bin/env bash
# Fixture test for the atc-gateway package, run locally with Docker. It touches no
# cluster, no tailnet and no cloud account.
#
# It runs the pinned atc-gateway release with the flags and the container security the
# Deployment sets (infra/build-atc-gateway-spec.ts). What this proves: the image builds
# from a checked binary, runs as nonroot on a read-only root, answers /healthz, /readyz
# and the metadata only on its public Host, keeps its state on the volume across a
# restart, and that state survives a backup, a wipe and a restore; a backup's retention
# groups the gateway's snapshots across source paths and leaves other snapshots alone.
# What it does not prove: gateway-to-daemon transport (the registry's daemon is a dead
# address), R2, k3s.
#
# The images build once per run, under per-run tags that the run removes. Each case then
# starts its own container on its own volumes and an ephemeral host port, and removes
# them when it exits.
#
#   bash scripts/test-atc-gateway-fixture.sh
#   CASE='foreign Host' bash scripts/test-atc-gateway-fixture.sh   # the cases whose title holds it
set -euo pipefail

it_answers_the_protected_resource_metadata_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

  diff - <(jq -S . "$tree/body") << 'EOF'
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
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/healthz")"

  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_readyz_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/readyz")"

  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

# the kubelet's probe reaches the pod by its IP, so the probe must set Host
it_refuses_healthz_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/healthz")"

  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_refuses_the_metadata_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_runs_the_gateway_process_as_the_nonroot_uid() {
  local gateway_image="$1"
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"

  start_gateway "$name" "$tree" "$gateway_image"

  diff - <(docker top "$name" -eo uid,gid,comm,pid | awk '{ print $1, $2, $3 }') << 'EOF'
UID GID COMMAND
65532 65532 atc-gateway
EOF
}

it_keeps_a_stored_client_across_a_restart() {
  local gateway_image="$1" client_id
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }

  docker restart "$name" > /dev/null
  wait_for_ready "$name"

  diff - <(docker exec "$name" /usr/local/bin/atc-gateway clients list) << EOF
$client_id  fixture-client  https://client.fixture.invalid/callback
EOF
}

# A backup reads the live databases while the gateway runs; the restore goes into the
# volume after the databases are wiped, and a new container finds the client again.
it_restores_a_stored_client_after_a_backup_a_wipe_and_a_restore() {
  local gateway_image="$1" backup_image="$2" restic_image="$3" client_id
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1; docker volume rm -f "$name-state" "$name-repo" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  docker volume create "$name-repo" > /dev/null
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }

  docker run --rm -v "$name-state:/state" -v "$name-repo:/repo" -e STATE_DIR=/state \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only "$backup_image" backup
  docker stop "$name" > /dev/null
  docker rm "$name" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$restic_image" -c 'rm -f /s/*.db*'
  diff /dev/null <(docker run --rm --user 0 --entrypoint /bin/ls -v "$name-state:/s" "$restic_image" -A /s)
  docker run --rm -v "$name-state:/state" -v "$name-repo:/repo" -e STATE_DIR=/state \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only "$backup_image" restore
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$restic_image" \
    -c 'chown -R 65532:65532 /s'
  start_gateway "$name" "$tree" "$gateway_image"

  diff - <(docker exec "$name" /usr/local/bin/atc-gateway clients list) << EOF
$client_id  fixture-client  https://client.fixture.invalid/callback
EOF
}

# Three gateway snapshots from older images, each from its own per-run temp path, all on
# one fixed day: grouped by host and tags, retention keeps the newest of that day (old-c)
# and the group's oldest (old-a, kept while keep-daily is not used up) and forgets old-b.
# Grouped by path, as restic does by default, each would keep itself.
it_groups_the_gateway_snapshots_across_source_paths_when_a_backup_prunes() {
  local backup_image="$2" restic_image="$3"
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only --entrypoint /bin/sh "$restic_image" -c 'restic init -q &&
    for s in a:10 b:11 c:12; do d="/tmp/old-${s%%:*}"; mkdir -p "$d" && echo old > "$d/gateway.db" &&
      (cd "$d" && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 ${s#*:}:00:00" .); done'
  docker run --rm --entrypoint sqlite3 -v "$name-state:/s" "$backup_image" /s/gateway.db \
    'CREATE TABLE fixture (x); INSERT INTO fixture VALUES (1);'

  docker run --rm -v "$name-state:/state" -v "$name-repo:/repo" -e STATE_DIR=/state \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only "$backup_image" backup

  diff - <(docker run --rm -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only "$restic_image" snapshots --json |
    jq -S '[.[] | {paths, tags, hostname, time: (if .paths == ["/tmp/atc-gateway-backup"] then "now" else .time end)}] | sort_by(.paths)') << 'EOF'
[
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/atc-gateway-backup"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "now"
  },
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/old-a"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "2020-01-06T10:00:00Z"
  },
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/old-c"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "2020-01-06T12:00:00Z"
  }
]
EOF
}

# The other tool's snapshot is older than every gateway snapshot and on the same fixed
# day, so it would be forgotten if retention did not filter by the gateway's host and tag.
it_leaves_another_tools_snapshot_alone_when_a_backup_prunes() {
  local backup_image="$2" restic_image="$3"
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree" "$name" "$3"
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only --entrypoint /bin/sh "$restic_image" -c 'restic init -q &&
    for s in a:10 b:11; do d="/tmp/old-${s%%:*}"; mkdir -p "$d" && echo old > "$d/gateway.db" &&
      (cd "$d" && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 ${s#*:}:00:00" .); done &&
    mkdir -p /tmp/other && echo other > /tmp/other/f && cd /tmp/other &&
    restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .'
  docker run --rm -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    "$restic_image" snapshots --json --tag other | jq -S . > "$tree/other-before"
  docker run --rm --entrypoint sqlite3 -v "$name-state:/s" "$backup_image" /s/gateway.db \
    'CREATE TABLE fixture (x); INSERT INTO fixture VALUES (1);'

  docker run --rm -v "$name-state:/state" -v "$name-repo:/repo" -e STATE_DIR=/state \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only "$backup_image" backup

  jq -e 'length == 1' "$tree/other-before" > /dev/null
  diff "$tree/other-before" <(docker run --rm -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only "$restic_image" snapshots --json --tag other | jq -S .)
}

# Boot data every case needs: the registry the gateway reads, whose daemon is a dead
# address (the gateway serves without reaching it), and a state volume owned by the
# nonroot uid, as fsGroup 65532 leaves the pod's new volume.
setup_case() {
  local tree="$1" name="$2" restic_image="$3"
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$restic_image" \
    -c 'chown 65532:65532 /s'
}

# The container as the Deployment runs it: a read-only root, no new privileges, every
# capability dropped, the same tmpfs mounts, env and args, on an ephemeral loopback port.
start_gateway() {
  local name="$1" tree="$2" image="$3"
  docker run -d --name "$name" --read-only --security-opt no-new-privileges --cap-drop ALL \
    --tmpfs /run/atc:uid=65532,gid=65532 --tmpfs /tmp:exec \
    --tmpfs /home/nonroot/.config:uid=65532,gid=65532 \
    -v "$name-state:/home/nonroot/.local/state/atc" -v "$tree/registry:/etc/atc-gateway:ro" \
    -p 127.0.0.1::8414 -e ATC_GATEWAY_TOKEN_GEOFFCLOUD=fixture-only \
    -e ATC_GATEWAY_STATE_DIR=/home/nonroot/.local/state/atc \
    "$image" serve --host 0.0.0.0 --port 8414 --public-url https://atc.fixture.invalid \
    --registry /etc/atc-gateway/registry.json --state-dir /home/nonroot/.local/state/atc > /dev/null
  wait_for_ready "$name"
}

# Polls /readyz on the public Host until it answers 200, for at most 30 seconds; past the
# deadline it prints the last answer and the container's logs and fails.
wait_for_ready() {
  local name="$1" port code="" deadline=$((SECONDS + 30))
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
      "http://127.0.0.1:$port/readyz" || true)"
    if [ "$code" = 200 ]; then return 0; fi
    sleep 0.2
  done
  echo "$name did not answer /readyz with 200 within 30s (last: ${code:-none})" >&2
  docker logs "$name" 2>&1 | tail -20 >&2
  return 1
}

# Builds both images once under per-run tags, then runs each it_* function (or those whose
# title holds $CASE) in its own background subshell, so errexit holds inside it, with the
# image names as arguments; prints ok or FAIL with the case's output. A case leaves its
# name and tree variables out of `local`, so its EXIT trap still sees them.
run_cases() {
  local repo work gateway_image backup_image fn title status failures=0 ran=0
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # sets BASE_IMAGE and RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/deploy/atc-gateway/versions.env"
  work="$(mktemp -d)"
  gateway_image="atc-gateway:fixture-$$"
  backup_image="atc-gateway-backup:fixture-$$"
  # expanded now: the trap runs after run_cases returns and its locals are gone
  # shellcheck disable=SC2064
  trap "docker rmi -f '$gateway_image' '$backup_image' > /dev/null 2>&1; rm -rf '$work'" EXIT
  # shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
  if ! {
    "$repo/scripts/fetch-atc-release.sh" "$work/context" &&
      cp "$repo/deploy/atc-gateway/Dockerfile" "$work/context/" &&
      docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$gateway_image" "$work/context" &&
      docker build -q --build-arg "RESTIC_IMAGE=$RESTIC_IMAGE" -t "$backup_image" \
        "$repo/deploy/atc-gateway/backup"
  } > "$work/build.log" 2>&1; then
    echo "FAIL the images did not build from the pinned, checked binary and pinned bases"
    sed 's/^/    /' "$work/build.log"
    exit 1
  fi
  echo "built $gateway_image and $backup_image"
  for fn in $(compgen -A function it_); do
    title="${fn//_/ }"
    [[ "$title" == *"${CASE:-}"* ]] || continue
    ran=$((ran + 1))
    (
      set -euo pipefail
      "$fn" "$gateway_image" "$backup_image" "$RESTIC_IMAGE"
    ) > "$work/case.log" 2>&1 &
    status=0
    wait "$!" || status=$?
    if [ "$status" = 0 ]; then
      echo "ok $title"
    else
      echo "FAIL $title (exit $status)"
      sed 's/^/    /' "$work/case.log"
      failures=$((failures + 1))
    fi
  done
  echo "$ran cases, $failures failed"
  [ "$ran" -gt 0 ] && [ "$failures" = 0 ] || exit 1
}

run_cases
