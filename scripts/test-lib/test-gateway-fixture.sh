#!/usr/bin/env bash
# Test for gateway-fixture.sh, the Docker helpers of the atc-gateway fixture suite:
# start_gateway runs the gateway as the Deployment does and returns once it is ready,
# wait_for_ready waits for /readyz or fails with the container's logs, and run_backup and
# run_backup_shell run the backup image as the backup pods do. It needs Docker and the
# real images, which it builds once under per-run tags that the run removes; each case
# creates its own containers and volumes and removes them when it exits.
#
#   bash scripts/test-lib/test-gateway-fixture.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gateway-fixture.sh"

it_starts_the_gateway_with_the_deployments_container_security_env_and_args() {
  local gateway_image="$1" backup_image="$2"
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$backup_image" \
    -c 'chown 65532:65532 /s'

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

it_returns_from_start_gateway_only_once_readyz_answers_200() {
  local gateway_image="$1" backup_image="$2" port code
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$backup_image" \
    -c 'chown 65532:65532 /s'

  start_gateway "$name" "$tree" "$gateway_image"

  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
  code="$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/readyz")"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_waits_for_readyz_after_a_restart() {
  local gateway_image="$1" backup_image="$2" port code status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" > /dev/null || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/registry"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" "$backup_image" \
    -c 'chown 65532:65532 /s'
  start_gateway "$name" "$tree" "$gateway_image"
  docker restart "$name" > /dev/null

  wait_for_ready "$name" > "$tree/out" 2> "$tree/err" || status=$?

  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
  code="$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/readyz")"
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The container publishes 8414 but nothing listens there, so /readyz never answers; the
# 30-second deadline is the helper's own, so this case takes that long. Docker keeps no
# order between a container's stdout and stderr lines, so the case compares the log lines
# after the timeout as a sorted set.
it_fails_wait_for_ready_with_the_containers_logs_when_readyz_never_answers() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$backup_image" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exec sleep 300' > /dev/null

  wait_for_ready "$name" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - <(head -n 1 "$tree/err") <<< "timed out after 30s waiting for $name to answer /readyz with 200"
  diff - <(tail -n +2 "$tree/err" | sort) << 'EOF'
a log line on stderr
a log line on stdout
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_runs_the_backup_image_as_the_backup_pods_do() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" -v "$name-repo:/r" \
    "$backup_image" -c 'chown 65532:65532 /s /r'
  cat > "$tree/probe.sh" << 'EOF'
id -u
id -g
echo "HOME=$HOME STATE_DIR=$STATE_DIR RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD SNAPSHOT=$SNAPSHOT"
grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
touch /tmp/w /state/w /repo/w && echo wrote /tmp, /state and /repo
printf '<%s>\n' "$@"
EOF
  chmod -R a+rX "$tree"

  run_backup "$name" "$backup_image" -e SNAPSHOT=abc12345 -v "$tree/probe.sh:/probe.sh:ro" \
    --entrypoint /bin/sh /probe.sh one "two words" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'EOF'
65532
65532
HOME=/tmp STATE_DIR=/state RESTIC_REPOSITORY=/repo RESTIC_PASSWORD=fixture-only SNAPSHOT=abc12345
CapEff:	0000000000000000
NoNewPrivs:	1
/tmp tmpfs
wrote /tmp, /state and /repo
<one>
<two words>
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_runs_the_backup_entrypoint_with_the_arguments_and_returns_its_exit_status() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null

  run_backup "$name" "$backup_image" prune > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: atc-gateway-backup backup|restore|ls'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_runs_the_backup_shell_script_from_stdin_as_the_backup_pods_do_with_the_seed_read_only() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" -v "$name-repo:/r" \
    "$backup_image" -c 'chown 65532:65532 /s /r'
  mkdir "$tree/seed"
  echo seeded > "$tree/seed/note"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"

  run_backup_shell "$name" "$backup_image" "$tree" > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
id -u
id -g
echo "HOME=$HOME RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD STATE_DIR=${STATE_DIR:-unset}"
grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
touch /tmp/w /state/w /repo/w && echo wrote /tmp, /state and /repo
cat /seed/note
if touch /seed/w 2> /dev/null; then echo /seed is writable; else echo /seed is read-only; fi
EOF

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'EOF'
65532
65532
HOME=/tmp RESTIC_REPOSITORY=/repo RESTIC_PASSWORD=fixture-only STATE_DIR=unset
CapEff:	0000000000000000
NoNewPrivs:	1
/tmp tmpfs
wrote /tmp, /state and /repo
seeded
/seed is read-only
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_the_backup_shell_at_the_first_failing_command() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/seed"
  chmod -R a+rX "$tree"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'echo before; false; echo after' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< before
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_shares_the_state_and_repository_volumes_between_run_backup_shell_and_run_backup() {
  local backup_image="$2" status=0
  name="atc-gw-lib-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" -v "$name-repo:/r" \
    "$backup_image" -c 'chown 65532:65532 /s /r'
  mkdir "$tree/seed"
  chmod -R a+rX "$tree"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'echo in state > /state/marker; echo in repo > /repo/marker'

  run_backup "$name" "$backup_image" --entrypoint /bin/cat /state/marker /repo/marker \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'EOF'
in state
in repo
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# Boot data every case needs: both images, built once under per-run tags that the run
# removes, as the fixture suite builds them.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# sets BASE_IMAGE and RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"
work="$(mktemp -d)"
gateway_image="atc-gateway:fixture-lib-$$"
backup_image="atc-gateway-backup:fixture-lib-$$"
trap 'docker rmi -f "$gateway_image" "$backup_image" > /dev/null 2>&1 || true; rm -rf "$work" || true' EXIT
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
run_cases "$gateway_image" "$backup_image"
