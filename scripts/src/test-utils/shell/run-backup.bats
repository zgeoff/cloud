#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Test for run-backup.sh: run_backup runs the backup image as the backup pods do, with
# docker run options and entrypoint arguments. It needs Docker and the real images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it ends.
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='exit status' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

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
  load 'run-backup.sh'
  load 'run-backup-shell.sh'
  load 'normalize-restic-output.sh'
  load 'wait-for.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-backup-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
  client=""
}

# client is the background run_backup of the case that starts one
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

# The probe writes each observation, with its command's exit status, to its own file in a
# case directory mounted at /obs, so each one is checked on its own after one run.
@test "it runs the backup image as the backup pods do" {
  setup_test
  mkdir "$tree/obs"
  chmod 0777 "$tree/obs"
  cat > "$tree/probe.sh" << 'EOF'
write_observation() {
  name="$1" status=0
  shift
  "$@" > "/obs/$name" 2>&1 || status=$?
  echo "exit $status" >> "/obs/$name"
}
write_observation uid id -u
write_observation gid id -g
write_observation env sh -c 'echo "HOME=$HOME STATE_DIR=$STATE_DIR RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD SNAPSHOT=$SNAPSHOT"'
write_observation privileges grep -E '^(NoNewPrivs|CapEff):' /proc/self/status
write_observation tmp-mount awk '$2 == "/tmp" { print $2, $3 }' /proc/mounts
write_observation tmp-write touch /tmp/w
write_observation state-write touch /state/w
write_observation repo-write touch /repo/w
write_observation args printf '<%s>\n' "$@"
EOF
  chmod a+r "$tree/probe.sh"

  run -0 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" -e SNAPSHOT=abc12345 -v "$tree/probe.sh:/probe.sh:ro" \
    -v "$tree/obs:/obs" --entrypoint /bin/sh /probe.sh one "two words"

  refute_output
  refute_stderr
  printf '65532\nexit 0\n' | diff - "$tree/obs/uid"
  printf '65532\nexit 0\n' | diff - "$tree/obs/gid"
  printf 'HOME=/tmp STATE_DIR=/state RESTIC_REPOSITORY=/repo RESTIC_PASSWORD=fixture-only SNAPSHOT=abc12345\nexit 0\n' | diff - "$tree/obs/env"
  printf 'CapEff:\t0000000000000000\nNoNewPrivs:\t1\nexit 0\n' | diff - "$tree/obs/privileges"
  printf '/tmp tmpfs\nexit 0\n' | diff - "$tree/obs/tmp-mount"
  diff - "$tree/obs/tmp-write" <<< 'exit 0'
  diff - "$tree/obs/state-write" <<< 'exit 0'
  diff - "$tree/obs/repo-write" <<< 'exit 0'
  printf '<one>\n<two words>\nexit 0\n' | diff - "$tree/obs/args"
}

# ls is the one mode that lists the repository's gateway snapshots, so a dropped or
# changed mode argument gives other output; each ID is random, so the case masks it
@test "it runs the backup entrypoint with the arguments" {
  setup_test
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/a && echo a > /tmp/a/gateway.db
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
EOF

  run -0 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" ls

  refute_stderr
  normalize_restic_output <<< "$output" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
ID        Time                 Host         Tags         Paths   Size
---------------------------------------------------------------------
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  /tmp/a  SIZE
---------------------------------------------------------------------
1 snapshots
EOF
}

# restic exits 10 when the repository does not exist, a status no other path gives
@test "it returns the backup entrypoints exit status" {
  setup_test

  run -10 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" ls

  refute_output
  assert_stderr - << 'EOF'
Fatal: repository does not exist: unable to open config file: stat /repo/config: no such file or directory
Is there a repository at the following location?
/repo
EOF
}

@test "it refuses a docker run option without a value" {
  setup_test

  run -2 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" --version

  refute_output
  assert_stderr 'run_backup: the docker run option --version has no value'
}

# A teardown removes the containers by name, so a run that is interrupted leaves none behind.
@test "it names the backup container after the case while it runs" {
  setup_test

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" --entrypoint /bin/sleep 300 > /dev/null 2>&1 3>&- &
  client=$!

  wait_for 30 "the container $name-backup to run" docker exec "$name-backup" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}}' "$name-backup" > "$tree/container"
  diff - "$tree/container" <<< "/$name-backup true"
  docker inspect -f '{{.HostConfig.AutoRemove}}' "$name-backup" > "$tree/auto-remove"
  diff - "$tree/auto-remove" <<< true
}

@test "it shares the state volume between run backup shell and run backup" {
  setup_test
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'echo in state > /state/marker'

  run -0 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" --entrypoint /bin/cat /state/marker

  assert_output 'in state'
  refute_stderr
}

@test "it shares the repository volume between run backup shell and run backup" {
  setup_test
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'echo in repo > /repo/marker'

  run -0 --separate-stderr run_backup "$name" "$FIXTURE_BACKUP_IMAGE" --entrypoint /bin/cat /repo/marker

  assert_output 'in repo'
  refute_stderr
}
