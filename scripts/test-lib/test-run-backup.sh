#!/usr/bin/env bash
# Test for run-backup.sh: run_backup runs the backup image as the backup pods do, with
# docker run options and entrypoint arguments. It needs Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it exits.
#
#   bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-run-backup.sh
#   CASE='exit status' bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-run-backup.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-backup.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/normalize-restic-output.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

# The probe writes each observation, with its command's exit status, to its own file in a
# case directory mounted at /obs, so each one is checked on its own after one run.
it_runs_the_backup_image_as_the_backup_pods_do() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"
  mkdir "$tree/obs"
  chmod 0777 "$tree/obs"
  cat > "$tree/probe.sh" << 'EOF'
observe() {
  name="$1" status=0
  shift
  "$@" > "/obs/$name" 2>&1 || status=$?
  echo "exit $status" >> "/obs/$name"
}
observe uid id -u
observe gid id -g
observe env sh -c 'echo "HOME=$HOME STATE_DIR=$STATE_DIR RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD SNAPSHOT=$SNAPSHOT"'
observe privileges grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
observe tmp-mount awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
observe tmp-write touch /tmp/w
observe state-write touch /state/w
observe repo-write touch /repo/w
observe args printf '<%s>\n' "$@"
EOF
  chmod a+r "$tree/probe.sh"

  run_backup "$name" "$backup_image" -e SNAPSHOT=abc12345 -v "$tree/probe.sh:/probe.sh:ro" \
    -v "$tree/obs:/obs" --entrypoint /bin/sh /probe.sh one "two words" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  printf '65532\nexit 0\n' | diff - "$tree/obs/uid"
  printf '65532\nexit 0\n' | diff - "$tree/obs/gid"
  printf 'HOME=/tmp STATE_DIR=/state RESTIC_REPOSITORY=/repo RESTIC_PASSWORD=fixture-only SNAPSHOT=abc12345\nexit 0\n' | diff - "$tree/obs/env"
  printf 'CapEff:\t0000000000000000\nNoNewPrivs:\t1\nexit 0\n' | diff - "$tree/obs/privileges"
  printf '/tmp tmpfs\nexit 0\n' | diff - "$tree/obs/tmp-mount"
  diff - "$tree/obs/tmp-write" <<< 'exit 0'
  diff - "$tree/obs/state-write" <<< 'exit 0'
  diff - "$tree/obs/repo-write" <<< 'exit 0'
  printf '<one>\n<two words>\nexit 0\n' | diff - "$tree/obs/args"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# ls is the one mode that lists the repository's gateway snapshots, so a dropped or
# changed mode argument gives other output; each ID is random, so the case masks it
it_runs_the_backup_entrypoint_with_the_arguments() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"
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
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

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
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  run_backup "$name" "$backup_image" --version > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run_backup: the docker run option --version has no value'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

# A trap removes the containers by name, so a run that is interrupted leaves none behind.
# client is global, as name and tree are: the EXIT trap runs after the case function has
# returned, when a local would be gone and the client would never be killed.
it_names_the_backup_container_after_the_case_while_it_runs() {
  local backup_image="$2" run="$3"
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  client=""
  trap '[ -z "${client:-}" ] || pkill -P "$client" 2> /dev/null || true; [ -z "${client:-}" ] || kill "$client" 2> /dev/null || true; docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  run_backup "$name" "$backup_image" --entrypoint /bin/sleep 300 > /dev/null 2>&1 &
  client=$!

  wait_for 30 "the container $name-backup to run" docker exec "$name-backup" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}}' "$name-backup" > "$tree/container"
  diff - "$tree/container" <<< "/$name-backup true"
  docker inspect -f '{{.HostConfig.AutoRemove}}' "$name-backup" > "$tree/auto-remove"
  diff - "$tree/auto-remove" <<< true
}

it_shares_the_state_and_repository_volumes_between_run_backup_shell_and_run_backup() {
  local backup_image="$2" run="$3" state_status=0 repo_status=0
  name="atc-gw-backup-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'echo in state > /state/marker; echo in repo > /repo/marker'

  run_backup "$name" "$backup_image" --entrypoint /bin/cat /state/marker \
    > "$tree/state-out" 2> "$tree/state-err" || state_status=$?
  run_backup "$name" "$backup_image" --entrypoint /bin/cat /repo/marker \
    > "$tree/repo-out" 2> "$tree/repo-err" || repo_status=$?

  diff - "$tree/state-out" <<< 'in state'
  diff /dev/null "$tree/state-err"
  [ "$state_status" = 0 ] || { echo "state read exit $state_status, want 0" >&2; exit 1; }
  diff - "$tree/repo-out" <<< 'in repo'
  diff /dev/null "$tree/repo-err"
  [ "$repo_status" = 0 ] || { echo "repo read exit $repo_status, want 0" >&2; exit 1; }
}

# Boot data every case needs: a seed directory that run_backup_shell mounts at /seed,
# writable by the nonroot uid so that only the read-only mount refuses a write, and a
# state volume and a restic repository volume owned by the nonroot uid, as fsGroup 65532
# leaves the pod's new volume. Its chown container is named for the case's trap.
setup_test() {
  local tree="$1" name="$2" backup_image="$3"
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$backup_image" -c 'chown 65532:65532 /s /r'
}

: "${FIXTURE_RUN:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
run_cases "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" "$FIXTURE_RUN"
