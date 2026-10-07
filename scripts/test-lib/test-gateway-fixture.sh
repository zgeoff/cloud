#!/usr/bin/env bash
# Test for the Docker helpers of the atc-gateway fixture suite: start-gateway.sh runs the
# gateway as the Deployment does and returns once it is ready, wait-for-ready.sh waits
# for /readyz or fails with the container's logs, and run-backup.sh and
# run-backup-shell.sh run the backup image as the backup pods do. One file tests all
# four, because they share the real images, which it builds once under tags carrying a
# random per-run id that the run removes; each case names its containers and volumes
# from that id and removes them when it exits, so concurrent runs on one daemon never
# share them.
#
#   bash scripts/test-lib/test-gateway-fixture.sh
#   CASE='after a restart' bash scripts/test-lib/test-gateway-fixture.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-gateway.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for-ready.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-backup.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/normalize-restic-output.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

it_starts_the_gateway_with_the_deployments_container_security_env_and_args() {
  local gateway_image="$1" backup_image="$2" run="$3"
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

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
  local gateway_image="$1" backup_image="$2" run="$3"
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  start_gateway "$name" "$tree" "$gateway_image"

  docker logs "$name" > "$tree/log.out" 2> "$tree/log.err"
  diff - "$tree/log.out" <<< 'atc-gateway: serving https://atc.fixture.invalid/mcp, listening on http://0.0.0.0:8414'
  sed -E 's/ [0-9.]+ms$/ Tms/' "$tree/log.err" > "$tree/requests"
  diff - "$tree/requests" <<< 'GET /readyz 200 Tms'
}

# As above: one answered poll from start_gateway before the restart, and one from
# wait_for_ready after it. Every poll that wait_for_ready makes follows the restart.
it_waits_for_readyz_after_a_restart() {
  local gateway_image="$1" backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"
  start_gateway "$name" "$tree" "$gateway_image"
  docker restart "$name" > /dev/null

  wait_for_ready "$name" 30 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
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
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The container publishes 8414 but nothing listens there, so /readyz never answers before
# the one-second deadline. Docker keeps no order between a container's stdout and stderr
# lines, so the case compares the log lines after the timeout as a sorted set.
it_fails_wait_for_ready_with_the_containers_logs_when_readyz_never_answers() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$backup_image" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exec sleep 300' > /dev/null

  wait_for_ready "$name" 1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - <(head -n 1 "$tree/err") <<< "timed out after 1s waiting for $name to answer /readyz with 200"
  diff - <(tail -n +2 "$tree/err" | sort) << 'EOF'
a log line on stderr
a log line on stdout
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The container has exited before the helper starts, so the helper reports it at once
# instead of polling a port that is gone until the 30-second deadline.
it_fails_wait_for_ready_with_the_containers_logs_as_soon_as_the_container_stops() {
  local backup_image="$2" run="$3" started elapsed status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  docker run -d --name "$name" -p 127.0.0.1::8414 --entrypoint /bin/sh "$backup_image" \
    -c 'echo a log line on stdout; echo a log line on stderr >&2; exit 3' > /dev/null
  docker wait "$name" > /dev/null
  started="$SECONDS"

  wait_for_ready "$name" 30 > "$tree/out" 2> "$tree/err" || status=$?

  elapsed=$((SECONDS - started))
  diff /dev/null "$tree/out"
  diff - <(head -n 1 "$tree/err") <<< "$name stopped before it answered /readyz with 200"
  diff - <(tail -n +2 "$tree/err" | sort) << 'EOF'
a log line on stderr
a log line on stdout
EOF
  [ "$elapsed" -le 5 ] || { echo "returned after ${elapsed}s, want at most 5" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_runs_the_backup_image_as_the_backup_pods_do() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"
  cat > "$tree/probe.sh" << 'EOF'
id -u
id -g
echo "HOME=$HOME STATE_DIR=$STATE_DIR RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD SNAPSHOT=$SNAPSHOT"
grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
touch /tmp/w /state/w /repo/w && echo wrote /tmp, /state and /repo
printf '<%s>\n' "$@"
EOF
  chmod a+r "$tree/probe.sh"

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

# ls is the one mode that lists the repository's gateway snapshots, so a dropped or
# changed mode argument gives other output; each ID is random, so the case masks it
it_runs_the_backup_entrypoint_with_the_arguments() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/a && echo a > /tmp/a/gateway.db
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$backup_image" ls > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
ID        Time                 Host         Tags         Paths   Size
---------------------------------------------------------------------
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  /tmp/a  SIZE
---------------------------------------------------------------------
1 snapshots
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# restic exits 10 when the repository does not exist, a status no other path gives
it_returns_the_backup_entrypoints_exit_status() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  run_backup "$name" "$backup_image" ls > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
Fatal: repository does not exist: unable to open config file: stat /repo/config: no such file or directory
Is there a repository at the following location?
/repo
EOF
  [ "$status" = 10 ] || { echo "exit $status, want 10" >&2; exit 1; }
}

it_refuses_a_docker_run_option_without_a_value() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  run_backup "$name" "$backup_image" --version > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run_backup: the docker run option --version has no value'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

# A trap removes the containers by name, so a run that is interrupted leaves none behind
it_names_the_backup_container_after_the_case_while_it_runs() {
  local backup_image="$2" run="$3"
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  run_backup "$name" "$backup_image" --entrypoint /bin/sleep 300 > /dev/null 2>&1 &

  wait_for 30 "the container $name-backup to run" docker exec "$name-backup" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}} {{.HostConfig.AutoRemove}}' "$name-backup" > "$tree/container"
  diff - "$tree/container" <<< "/$name-backup true true"
}

it_names_the_backup_shell_container_after_the_case_while_it_runs() {
  local backup_image="$2" run="$3"
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'exec sleep 300' > /dev/null 2>&1 &

  wait_for 30 "the container $name-shell to run" docker exec "$name-shell" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}} {{.HostConfig.AutoRemove}}' "$name-shell" > "$tree/container"
  diff - "$tree/container" <<< "/$name-shell true true"
}

it_runs_the_backup_shell_script_from_stdin_as_the_backup_pods_do_with_the_seed_read_only() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"
  echo seeded > "$tree/seed/note"

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
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'echo before; false; echo after' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< before
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_shares_the_state_and_repository_volumes_between_run_backup_shell_and_run_backup() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-lib-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$backup_image"
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

# Boot data every case that calls it needs: a seed directory that run_backup_shell mounts
# at /seed, writable by the nonroot uid so that only the read-only mount refuses a write,
# and a state volume and a restic repository volume owned by the nonroot uid, as fsGroup
# 65532 leaves the pod's new volume. Its chown container is named for the case's trap.
setup_case() {
  local tree="$1" name="$2" backup_image="$3"
  mkdir "$tree/registry" "$tree/seed"
  # start_gateway mounts it; the gateway exits at boot without it, and serves without
  # reaching its daemon, a dead address
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$backup_image" -c 'chown 65532:65532 /s /r'
}

# Boot data every case needs: both images, built once under per-run tags that the run
# removes, as the fixture suite builds them, and the random per-run id that the image
# tags and every case's container and volume names carry.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# sets BASE_IMAGE and RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
work="$(mktemp -d)"
gateway_image="atc-gateway:fixture-lib-$run"
backup_image="atc-gateway-backup:fixture-lib-$run"
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
run_cases "$gateway_image" "$backup_image" "$run"
