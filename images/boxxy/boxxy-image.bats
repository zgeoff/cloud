#!/usr/bin/env bats
# bats file_tags=suite:boxxy-image
# Image test for the boxxy server (images/boxxy/Dockerfile), run locally with Docker. It touches no
# cluster, no atc daemon and no cloud account.
#
# It runs the image as the cluster runs it: as uid 65532, on a read-only root, with no
# capabilities and no privilege escalation, its configuration file mounted read-only at
# /etc/boxxy/config.json, its volume at /data owned by that user, and a rules folder read-only at
# /rules, since the image holds none. What this proves: the compiled binary starts on the base that
# images/boxxy/versions.env pins, loads the test's rules folder (images/boxxy/test-rules), prompts
# included, loads its rules through git from a checkout that git-sync wrote and another uid owns,
# opens its SQLite store on the volume and keeps it across a restart, answers
# /healthz on the owner port, refuses a request a browser page sent with 403, answers 401 on the
# worker port without the worker token, and exits 1 naming each missing token. What it does not
# prove: k3s, the git-sync sidecar's fetch from GitHub, the atc daemon the runner tick calls, the
# broker, pepys.
#
# images/boxxy/run-image-tests.sh builds the image under a tag that carries a random per-run id,
# sets BOXXY_IMAGE and BOXXY_RUN, runs this suite, and removes the image. Each case starts its own
# container on its own volume and two ephemeral loopback ports, named from that id.
#
#   bash images/boxxy/run-image-tests.sh
#   CASE='restart' bash images/boxxy/run-image-tests.sh

# a case starts a chown container and the server, and waits up to 30 seconds for its healthz
export BATS_TEST_TIMEOUT=120

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
  : "${BOXXY_IMAGE:?is unset: run this through images/boxxy/run-image-tests.sh}"
  : "${BOXXY_RUN:?is unset: run this through images/boxxy/run-image-tests.sh}"
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/wait-for.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="boxxy-image-$BOXXY_RUN-$BATS_SUITE_TEST_NUMBER"
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # the pinned restic image, which has a shell, chowns each volume and lists it
  # sets RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/images/atc-gateway/versions.env"
  # sets GIT_SYNC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/images/boxxy/versions.env"
  # shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
  restic_image="$RESTIC_IMAGE"
  image="$BOXXY_IMAGE"
}

teardown() {
  stop_timeout_watchdog
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker volume rm -f "$name-data" "$name-rules" > /dev/null || true
}

# create_rules_source <dir>: a git repository at <dir> whose main holds one commit of the test's
# rules, readable by every uid, so git-sync's uid can fetch it; prints the commit. It reads no git
# config of the caller's.
create_rules_source() {
  local dir="$1"
  mkdir "$dir"
  cp -R "$repo/images/boxxy/test-rules/." "$dir/"
  (
    cd "$dir" || return 1
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git init -q -b main
    git config maintenance.auto false
    git add -A
    git -c user.name='Image Test' -c user.email=image-test@example.invalid -c commit.gpgsign=false \
      commit -q -m 'add the rules'
    git rev-parse HEAD
  )
  chmod -R a+rX "$dir"
}

# a configuration with the listeners, store, rules folder and review agent scope that
# infra/cluster/render-boxxy-config.ts sets, so the rules load as the cluster loads them, its
# trustedIssuers section when the second argument is set, the rules section in the third argument
# in place of the plain folder at /rules, and an atc address that refuses every connection, so the runner
# tick fails and logs and the listeners keep serving
write_config() {
  local tree="$1" trusted="${2:-}" rules="${3:-}" issuers=''
  if [ -z "$rules" ]; then
    rules='{ "folder": "/rules" }'
  fi
  if [ -n "$trusted" ]; then
    issuers='"trustedIssuers": { "folders": ["/etc/boxxy-issuers"], "audience": "boxxy.imp.internal" },'
  fi
  cat > "$tree/config.json" << EOF
{
  $issuers
  "runner": "image-test",
  "store": { "file": "/data/boxxy.db" },
  "rules": $rules,
  "api": {
    "listen": { "hostname": "0.0.0.0", "port": 8090 },
    "workerListen": { "hostname": "0.0.0.0", "port": 8091 }
  },
  "spawn": {
    "target": "image-test",
    "repos": {},
    "agents": { "boxxy-review": { "phases": ["review"] } },
    "phases": { "review": { "requireScopedAgent": true } }
  },
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
    -v "$repo/images/boxxy/test-rules:/rules:ro" -p 127.0.0.1::8090 -p 127.0.0.1::8091 \
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

@test "it answers healthz on the owner port and opens its store on the volume" {
  local body
  setup_test "$tree" "$name" "$image" "$restic_image"

  body="$(curl -q --noproxy '*' -sS "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"

  assert_equal "$body" ok
  diff - <(docker run --rm --entrypoint /bin/ls -v "$name-data:/data" "$restic_image" /data | LC_ALL=C sort) << 'EOF'
boxxy.db
boxxy.db-shm
boxxy.db-wal
EOF
}

@test "it refuses a request that a browser page sent with 403" {
  local origin site
  setup_test "$tree" "$name" "$image" "$restic_image"

  origin="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H 'Origin: https://page.fixture.invalid' \
    "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"
  site="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: cross-site' \
    "http://127.0.0.1:$(cat "$tree/owner-port")/healthz")"

  assert_equal "$origin" 403
  assert_equal "$site" 403
}

@test "it answers 401 on the worker port without the worker token" {
  local missing wrong
  setup_test "$tree" "$name" "$image" "$restic_image"
  printf 'Authorization: Bearer %s\n' not-the-worker-token > "$tree/wrong.headers"

  missing="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$(cat "$tree/worker-port")/rpc/runner/status")"
  wrong="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "@$tree/wrong.headers" "http://127.0.0.1:$(cat "$tree/worker-port")/rpc/runner/status")"

  assert_equal "$missing" 401
  assert_equal "$wrong" 401
}

@test "it keeps its store on its volume across a restart" {
  local before after port
  setup_test "$tree" "$name" "$image" "$restic_image"
  before="$(docker run --rm --entrypoint /bin/sh -v "$name-data:/data" "$restic_image" -c 'stat -c %i /data/boxxy.db')"

  docker restart "$name" > /dev/null
  port="$(docker port "$name" 8090/tcp)"
  port="${port##*:}"
  wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"
  after="$(docker run --rm --entrypoint /bin/sh -v "$name-data:/data" "$restic_image" -c 'stat -c %i /data/boxxy.db')"

  assert_equal "$after" "$before"
}

@test "it exits 1 and names each missing token" {
  write_config "$tree"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  run -1 --separate-stderr docker run --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    -v "$repo/images/boxxy/test-rules:/rules:ro" \
    "$image"

  refute_output
  assert_stderr 'set these variables: BOXXY_WORKER_TOKEN, BOXXY_ATC_TOKEN'
}

@test "it starts with each trust document of the repo mounted as a file" {
  local file port mounts=()
  write_config "$tree" trusted
  # one file mount per document, as the pod's subPath mounts give them
  for file in "$repo"/deploy/boxxy/issuers/*.json; do
    mounts+=(-v "$file:/etc/boxxy-issuers/$(basename "$file"):ro")
  done
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" "${mounts[@]}" \
    -v "$repo/images/boxxy/test-rules:/rules:ro" \
    -p 127.0.0.1::8090 \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    "$image" > /dev/null
  port="$(docker port "$name" 8090/tcp)"

  if ! wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:${port##*:}/healthz"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
}

@test "it exits 1 on a trust document that is not json" {
  write_config "$tree" trusted
  echo 'not json' > "$tree/broken.json"
  chmod a+r "$tree/broken.json"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'

  run -1 --separate-stderr docker run --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    -v "$repo/images/boxxy/test-rules:/rules:ro" -v "$tree/broken.json:/etc/boxxy-issuers/broken.json:ro" \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    "$image"

  assert_stderr 'the trust document at /etc/boxxy-issuers/broken.json is not JSON'
}

@test "it loads its rules from a git sync checkout that another uid owns" {
  local commit port loaded
  write_config "$tree" '' '{ "folder": "/rules/root/current", "ref": "git-sync" }'
  commit="$(create_rules_source "$tree/source")"
  docker volume create "$name-data" > /dev/null
  docker volume create "$name-rules" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" -v "$name-rules:/r" "$restic_image" \
    -c 'chown 65532:65532 /s && chown 65533:65533 /r'
  # one sync into the rules volume, as the pod's sidecar runs it: as git-sync's own uid, 65533
  docker run --rm --user 65533:65533 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-rules:/git" -v "$tree/source:/source:ro" \
    "$GIT_SYNC_IMAGE" --repo=file:///source --ref=main --root=/git/root --link=current --depth=1 \
    --one-time --git-config='safe.directory:*' > "$tree/sync.log" 2>&1 || {
    cat "$tree/sync.log" >&2
    return 1
  }

  docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -v "$name-rules:/rules:ro" -v "$tree/config.json:/etc/boxxy/config.json:ro" \
    -p 127.0.0.1::8090 \
    -e BOXXY_WORKER_TOKEN=worker-token-image-test -e BOXXY_ATC_TOKEN=atc-token-image-test \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
    "$image" > /dev/null
  port="$(docker port "$name" 8090/tcp)"
  port="${port##*:}"
  if ! wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
  loaded="$(curl -q --noproxy '*' -sS -X POST -H 'Content-Type: application/json' -d '{"json":{}}' \
    "http://127.0.0.1:$port/rpc/runner/status" | jq -r '.json.rules.commit')"

  assert_equal "$loaded" "$commit"
}
