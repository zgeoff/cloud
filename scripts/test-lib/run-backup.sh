# shellcheck shell=bash
# run_backup <name> <image> [<docker run option> <value>]... [<arg>...]: runs the backup
# image as the backup CronJob and the restore Job run it
# (infra/create-atc-gateway-backup-job.ts, deploy/atc-gateway/restore-job.yaml): uid and
# gid 65532, no privilege escalation, every capability dropped, HOME=/tmp on a writable
# /tmp (an emptyDir there), the volume <name>-state at /state and <name>-repo at /repo.
# Neither pod sets readOnlyRootFilesystem, so neither does this. Leading arguments that
# start with `-` go to `docker run` in pairs (such as -e SNAPSHOT=…), before the image;
# the rest go to the image's entrypoint. An option without a value is refused with exit 2
# before anything runs. The container is named <name>-backup and removed when it exits;
# a caller's trap removes it by that name when the run is interrupted.
run_backup() {
  local name="$1" image="$2"
  shift 2
  local options=()
  while [ "$#" -gt 0 ] && [[ "$1" == -* ]]; do
    if [ "$#" -lt 2 ]; then
      echo "run_backup: the docker run option $1 has no value" >&2
      return 2
    fi
    options+=("$1" "$2")
    shift 2
  done
  docker run --rm --name "$name-backup" --user 65532:65532 --security-opt no-new-privileges \
    --cap-drop ALL -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -e STATE_DIR=/state -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    "${options[@]}" "$image" "$@"
}
