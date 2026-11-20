#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Test for run-backup-shell.sh: run_backup_shell runs a script from stdin in the backup
# image as the backup pods do, with the seed read-only. It needs Docker and the real
# images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it ends.
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='first failing' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

# a case runs a chown container and then the backup image
export BATS_TEST_TIMEOUT=120

setup_file() {
  load '../bats/setup'
  : "${FIXTURE_RUN:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
}

setup() {
  load '../bats/setup'
  load 'run-backup-shell.sh'
  load 'wait-for.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-shell-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
  client=""
}

# client is the background run_backup_shell of the case that starts one
teardown() {
  stop_timeout_watchdog
  [ -z "${client:-}" ] || pkill -P "$client" 2> /dev/null || true
  [ -z "${client:-}" ] || kill "$client" 2> /dev/null || true
  docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true
  docker volume rm -f "$name-state" "$name-repo" > /dev/null || true
}

# Boot data every case needs: a seed directory that run_backup_shell mounts at /seed,
# writable by the nonroot uid so that only the read-only mount refuses a write, and a
# state volume and a restic repository volume owned by the nonroot uid, as fsGroup 65532
# leaves the pod's new volume. Its chown container is named for the case's teardown.
setup_test() {
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$FIXTURE_BACKUP_IMAGE" -c 'chown 65532:65532 /s /r'
}

# run_backup_shell mounts no case directory the probe could write, so the probe writes
# each observation, with its command's exit status, to its own file under /tmp/obs and
# streams them out as a tar archive on stdout; the case unpacks it and checks each file on
# its own after one run. The archive is bytes, so a bare command writes it to a file.
@test "it runs the backup shell script from stdin as the backup pods do with the seed read only" {
  setup_test
  echo seeded > "$tree/seed/note"
  mkdir "$tree/obs"

  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" > "$tree/out.tar" 2> "$tree/err" << 'EOF'
write_observation() {
  name="$1" status=0
  shift
  "$@" > "/tmp/obs/$name" 2>&1 || status=$?
  echo "exit $status" >> "/tmp/obs/$name"
}
mkdir /tmp/obs
write_observation uid id -u
write_observation gid id -g
write_observation env sh -c 'echo "HOME=$HOME RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD STATE_DIR=${STATE_DIR:-unset}"'
write_observation privileges grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
write_observation tmp-mount awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
write_observation tmp-write touch /tmp/w
write_observation state-write touch /state/w
write_observation repo-write touch /repo/w
write_observation seed-read cat /seed/note
write_observation seed-write touch /seed/w
tar -cf - -C /tmp/obs .
EOF

  diff /dev/null "$tree/err"
  tar -xf "$tree/out.tar" -C "$tree/obs"
  printf '65532\nexit 0\n' | diff - "$tree/obs/uid"
  printf '65532\nexit 0\n' | diff - "$tree/obs/gid"
  printf 'HOME=/tmp RESTIC_REPOSITORY=/repo RESTIC_PASSWORD=fixture-only STATE_DIR=unset\nexit 0\n' | diff - "$tree/obs/env"
  printf 'CapEff:\t0000000000000000\nNoNewPrivs:\t1\nexit 0\n' | diff - "$tree/obs/privileges"
  printf '/tmp tmpfs\nexit 0\n' | diff - "$tree/obs/tmp-mount"
  diff - "$tree/obs/tmp-write" <<< 'exit 0'
  diff - "$tree/obs/state-write" <<< 'exit 0'
  diff - "$tree/obs/repo-write" <<< 'exit 0'
  printf 'seeded\nexit 0\n' | diff - "$tree/obs/seed-read"
  printf "touch: /seed/w: Read-only file system\nexit 1\n" | diff - "$tree/obs/seed-write"
}

@test "it stops the backup shell at the first failing command" {
  setup_test

  run -1 --separate-stderr run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'echo before; false; echo after'

  assert_output before
  refute_stderr
}

@test "it replaces a default with a trailing docker run option" {
  setup_test

  # the shell in the container expands the command, so it stays unexpanded here
  # shellcheck disable=SC2016
  run -0 --separate-stderr run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    <<< 'echo "$(id -u):$(id -g) $STATE_DIR"'

  assert_output '10001:10001 /state'
  refute_stderr
}

@test "it refuses a trailing docker run option without a value" {
  setup_test

  run -2 --separate-stderr run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" --user <<< 'touch /state/ran'

  refute_output
  assert_stderr 'run_backup_shell: the docker run option --user has no value'
  run -0 --separate-stderr run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'ls -A /state'
  refute_output
}

@test "it names the backup shell container after the case while it runs" {
  setup_test

  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'exec sleep 300' > /dev/null 2>&1 3>&- &
  client=$!

  wait_for 30 "the container $name-shell to run" docker exec "$name-shell" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}}' "$name-shell" > "$tree/container"
  diff - "$tree/container" <<< "/$name-shell true"
  docker inspect -f '{{.HostConfig.AutoRemove}}' "$name-shell" > "$tree/auto-remove"
  diff - "$tree/auto-remove" <<< true
}
