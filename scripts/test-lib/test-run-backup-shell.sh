#!/usr/bin/env bash
# Test for run-backup-shell.sh: run_backup_shell runs a script from stdin in the backup
# image as the backup pods do, with the seed read-only. It needs Docker and the real
# images.
#
# The images come from with-fixture-images.sh, which builds them once per run and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE; each case names its
# containers and volumes from FIXTURE_RUN and removes them when it exits.
#
#   bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-run-backup-shell.sh
#   CASE='first failing' bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-run-backup-shell.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

it_runs_the_backup_shell_script_from_stdin_as_the_backup_pods_do_with_the_seed_read_only() {
  local backup_image="$2" run="$3" status=0
  name="atc-gw-shell-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"
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
  name="atc-gw-shell-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'echo before; false; echo after' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< before
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_names_the_backup_shell_container_after_the_case_while_it_runs() {
  local backup_image="$2" run="$3"
  name="atc-gw-shell-$run-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$backup_image"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'exec sleep 300' > /dev/null 2>&1 &

  wait_for 30 "the container $name-shell to run" docker exec "$name-shell" true > /dev/null 2>&1
  docker inspect -f '{{.Name}} {{.State.Running}} {{.HostConfig.AutoRemove}}' "$name-shell" > "$tree/container"
  diff - "$tree/container" <<< "/$name-shell true true"
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
