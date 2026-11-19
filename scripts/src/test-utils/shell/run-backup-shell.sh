# shellcheck shell=bash
# run_backup_shell <name> <image> <tree> [<docker run option> <value>]...: a shell in the
# backup image under the uid, security, volumes and repository that run_backup uses, with
# <tree>/seed read-only at /seed; it runs the script on stdin with errexit, for arranging
# snapshots and state and reading them back. Trailing arguments go to `docker run` in pairs
# after its defaults, so a later one replaces a default (such as --user 10001:10001 for
# nixie's backup). An option without a value is refused with exit 2 before anything runs.
# The container is named <name>-shell and removed when it exits; a caller's trap removes it
# by that name when the run is interrupted.
run_backup_shell() {
  local name="$1" image="$2" tree="$3"
  shift 3
  local options=()
  while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then
      echo "run_backup_shell: the docker run option $1 has no value" >&2
      return 2
    fi
    options+=("$1" "$2")
    shift 2
  done
  docker run --rm -i --name "$name-shell" --user 65532:65532 --security-opt no-new-privileges \
    --cap-drop ALL -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -v "$tree/seed:/seed:ro" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    "${options[@]}" --entrypoint /bin/sh "$image" -es
}
