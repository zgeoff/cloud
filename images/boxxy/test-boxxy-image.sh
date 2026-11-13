#!/usr/bin/env bash
# Image test for the boxxy server (images/boxxy/Dockerfile), run locally with Docker. It touches no
# cluster, no atc daemon and no cloud account.
#
# It runs the image as the cluster runs it: as its nonroot user, on a read-only root, with no
# capabilities and no privilege escalation, its configuration file mounted read-only at
# /etc/boxxy/config.json, and its volume at /data owned by that user. What this proves: the compiled
# binary starts on the distroless base, loads the image's rules from /rules, prompts included,
# opens its SQLite store on the volume and keeps it across a restart, answers /healthz on the owner
# port, refuses a request a browser page sent with 403, answers 401 on the worker port without the
# worker token, and exits 1 naming each missing token. What it does not prove: k3s, the atc daemon
# the runner tick calls, the broker, pepys.
#
# images/boxxy/run-image-tests.sh builds the image under a tag that carries a random per-run id,
# sets BOXXY_IMAGE and BOXXY_RUN, runs this suite, and removes the image. Each case starts its own
# container on its own volume and two ephemeral loopback ports, named from that id.
#
#   bash images/boxxy/run-image-tests.sh
#   CASE='restart' bash images/boxxy/run-image-tests.sh
# shell-suite: boxxy-image
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"

it_answers_healthz_on_the_owner_port_and_opens_its_store_on_the_volume() {
  local image="$1" restic_image="$2" run="$3" body
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"

  body="$(curl -q --noproxy '*' -sS "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"

  assert_equals ok "$body" '/healthz body'
  diff - <(docker run --rm --entrypoint /bin/ls -v "$name-data:/data" "$restic_image" /data | LC_ALL=C sort) << 'EOF'
boxxy.db
boxxy.db-shm
boxxy.db-wal
EOF
}

it_refuses_a_request_that_a_browser_page_sent_with_403() {
  local image="$1" restic_image="$2" run="$3" origin site
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"

  origin="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H 'Origin: https://page.fixture.invalid' \
    "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"
  site="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: cross-site' \
    "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"

  assert_equals 403 "$origin" 'status with an Origin header'
  assert_equals 403 "$site" 'status with Sec-Fetch-Site: cross-site'
}

it_answers_401_on_the_worker_port_without_the_worker_token() {
  local image="$1" restic_image="$2" run="$3" missing wrong
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  printf 'Authorization: Bearer %s\n' not-the-worker-token > "$tree/wrong.headers"

  missing="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/worker-port")/rpc/runner/status")"
  wrong="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "@$tree/wrong.headers" "http://127.0.0.1:$(cat "$tree/worker-port")/rpc/runner/status")"

  assert_equals 401 "$missing" 'status without a token'
  assert_equals 401 "$wrong" 'status with a wrong token'
}

it_keeps_its_store_on_its_volume_across_a_restart() {
  local image="$1" restic_image="$2" run="$3" before after port
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  before="$(docker run --rm --entrypoint /bin/sh -v "$name-data:/data" "$restic_image" -c 'stat -c %i /data/boxxy.db')"

  docker restart "$name" > /dev/null
  port="$(docker port "$name" 8090/tcp)"
  port="${port##*:}"
  wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"
  after="$(docker run --rm --entrypoint /bin/sh -v "$name-data:/data" "$restic_image" -c 'stat -c %i /data/boxxy.db')"

  assert_equals "$before" "$after" 'store file inode'
}

it_exits_1_and_names_each_missing_token() {
  local image="$1" restic_image="$2" run="$3" status=0
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  write_config "$tree"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  docker run --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    "$image" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'set these variables: BOXXY_WORKER_TOKEN, BOXXY_ATC_TOKEN'
  assert_status 1 "$status"
}

it_starts_with_each_trust_document_of_the_repo_mounted_as_a_file() {
  local image="$1" restic_image="$2" run="$3" file port mounts=()
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  write_config "$tree" trusted
  # one file mount per document, as the pod's subPath mounts give them
  for file in "$repo"/deploy/boxxy/issuers/*.json; do
    mounts+=(-v "$file:/etc/boxxy-issuers/$(basename "$file"):ro")
  done
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" "${mounts[@]}" \
    -p 127.0.0.1::8090 \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    "$image" > /dev/null
  port="$(docker port "$name" 8090/tcp)"

  if ! wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:${port##*:}/healthz"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
}

it_exits_1_on_a_trust_document_that_is_not_json() {
  local image="$1" restic_image="$2" run="$3" status=0
  name="boxxy-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  write_config "$tree" trusted
  echo 'not json' > "$tree/broken.json"
  chmod a+r "$tree/broken.json"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  docker run --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    -v "$tree/broken.json:/etc/boxxy-issuers/broken.json:ro" \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    "$image" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the trust document at /etc/boxxy-issuers/broken.json is not JSON'
  assert_status 1 "$status"
}

# a configuration with the listeners, store, rules folder and review agent that
# infra/cluster/render-boxxy-config.ts sets, so the image's rules load as the cluster loads them, its
# trustedIssuers section when the second argument is set, and an atc address that refuses
# every connection, so the runner tick fails and logs and the listeners keep serving
write_config() {
  local tree="$1" trusted="${2:-}" issuers=''
  if [ -n "$trusted" ]; then
    issuers='"trustedIssuers": { "folders": ["/etc/boxxy-issuers"], "audience": "boxxy.imp.internal" },'
  fi
  cat > "$tree/config.json" << EOF
{
  $issuers
  "runner": "image-test",
  "store": { "file": "/data/boxxy.db" },
  "rules": { "folder": "/rules" },
  "api": {
    "listen": { "hostname": "0.0.0.0", "port": 8090 },
    "workerListen": { "hostname": "0.0.0.0", "port": 8091 }
  },
  "spawn": { "target": "image-test", "repos": {}, "reviewAgents": ["boxxy-review"] },
  "atc": { "url": "http://127.0.0.1:1/mcp", "host": "atc.image-test.invalid", "trustedFolders": {} }
}
EOF
  chmod a+r "$tree/config.json"
}

# What every case but the missing-token one needs: a volume owned by the image's nonroot uid, as
# the pod's fsGroup leaves it, and the server on it with two fixed test tokens, as the cluster runs
# it. It writes the owner and worker loopback ports to $tree/owner-port and $tree/worker-port once
# /healthz answers.
setup_test() {
  local tree="$1" name="$2" image="$3" restic_image="$4" port
  write_config "$tree"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'
  docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    -p 127.0.0.1::8090 -p 127.0.0.1::8091 \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    "$image" > /dev/null
  port="$(docker port "$name" 8090/tcp)"
  port="${port##*:}"
  if ! wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
  echo "$port" > "$tree/owner-port"
  port="$(docker port "$name" 8091/tcp)"
  echo "${port##*:}" > "$tree/worker-port"
}

# the image and the run id come from run-image-tests.sh; the pinned restic image, which has a
# shell, chowns each volume and lists it
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# sets RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/images/atc-gateway/versions.env"
: "${BOXXY_IMAGE:?is unset: run this through images/boxxy/run-image-tests.sh}"
: "${BOXXY_RUN:?is unset: run this through images/boxxy/run-image-tests.sh}"
# shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
run_cases "$BOXXY_IMAGE" "$RESTIC_IMAGE" "$BOXXY_RUN"
