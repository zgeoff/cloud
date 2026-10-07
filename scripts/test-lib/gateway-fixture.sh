# shellcheck shell=bash
# The Docker helpers the atc-gateway fixture suite runs its cases with. Each takes the
# case's container name <name>, whose volumes <name>-state and <name>-repo the case
# creates and removes; none removes what it starts.
#
# start_gateway <name> <tree> <image>: runs the gateway image detached as the Deployment
# runs it (infra/build-atc-gateway-spec.ts): a read-only root, no new privileges, every
# capability dropped, the same tmpfs mounts, env and args, <name>-state as its state
# directory, <tree>/registry read-only at /etc/atc-gateway, and port 8414 published on an
# ephemeral loopback port. It returns once wait_for_ready does.
#
# wait_for_ready <name>: polls /readyz on the public Host (atc.fixture.invalid) until it
# answers 200, for at most 30 seconds; past the deadline it prints wait_for's timeout and
# the container's last 20 log lines to stderr and returns 1.
#
# run_backup <name> <image> [<docker run option> <value>]... [<arg>...]: the backup image
# as the backup CronJob and the restore Job run it (infra/create-atc-gateway-backup-job.ts,
# deploy/atc-gateway/restore-job.yaml): uid and gid 65532, no privilege escalation, every
# capability dropped, HOME=/tmp on a writable /tmp (an emptyDir there), <name>-state at
# /state, <name>-repo at /repo. Neither pod sets readOnlyRootFilesystem, so neither does
# this. Leading arguments that start with `-` go to `docker run` in pairs (such as
# -e SNAPSHOT=…), before the image; the rest go to the image's entrypoint.
#
# run_backup_shell <name> <image> <tree>: a shell in the backup image under the same uid
# and security, volumes and repository, with <tree>/seed read-only at /seed; it runs the
# script on stdin with errexit, for arranging snapshots and state and reading them back.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

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

wait_for_ready() {
  local name="$1" port
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
  if ! wait_for 30 "$name to answer /readyz with 200" is_ready "$port"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
}

is_ready() {
  [ "$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$1/readyz")" = 200 ]
}

run_backup() {
  local name="$1" image="$2"
  shift 2
  local options=()
  while [ "$#" -gt 0 ] && [[ "$1" == -* ]]; do
    options+=("$1" "$2")
    shift 2
  done
  docker run --rm --user 65532:65532 --security-opt no-new-privileges --cap-drop ALL \
    -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -e STATE_DIR=/state -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    "${options[@]}" "$image" "$@"
}

run_backup_shell() {
  local name="$1" image="$2" tree="$3"
  docker run --rm -i --user 65532:65532 --security-opt no-new-privileges --cap-drop ALL \
    -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -v "$tree/seed:/seed:ro" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    --entrypoint /bin/sh "$image" -es
}
