# shellcheck shell=bash
# run_backup_shell <name> <image> <tree>: a shell in the backup image under the uid,
# security, volumes and repository that run_backup uses, with <tree>/seed read-only at
# /seed; it runs the script on stdin with errexit, for arranging snapshots and state and
# reading them back. The container is named <name>-shell and removed when it exits; a
# caller's trap removes it by that name when the run is interrupted.
run_backup_shell() {
  local name="$1" image="$2" tree="$3"
  docker run --rm -i --name "$name-shell" --user 65532:65532 --security-opt no-new-privileges \
    --cap-drop ALL -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -v "$tree/seed:/seed:ro" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    --entrypoint /bin/sh "$image" -es
}
