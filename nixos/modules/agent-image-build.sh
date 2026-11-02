# shellcheck shell=bash
# Build and check the agent image of the newest commit on main that changes images/agent, when impd
# holds no image of that name yet. The script keeps a clone of $REPO_URL in $STATE_DIR/cloud and
# fetches its main without a credential. The image is agent-<short sha> of that commit, as
# scripts/build-agent-image.ts names it, and the script skips the run when impd lists that name,
# when no commit on main changes images/agent, or when a build of that commit failed before. A host
# switch can recreate imp-host while the timer fires, so the script lists impd's images until impd
# answers, pausing 5 s between AGENT_IMAGE_WAIT_TRIES tries (default 120), prints each failed try
# whose error differs from the one before, and skips the run when the tries run out. Each failed
# build leaves its time in $STATE_DIR/failed/<sha>, so a broken commit is built once, not at every
# run; removing that file builds it again at the next run. A build, or the copy of the CLI before
# it, that fails while imp-host's container changes, as a switch recreates it, says nothing of the
# commit: the run leaves no record, exits 0 and names both container IDs, and the next run builds
# the commit again. So does a run whose imp-host has no container once impd listed its images.
#
# To build, it copies imp's CLI out of the imp-host container with its mode, so the CLI always
# matches the impd it calls, checks out main's head, and runs that head's
# scripts/build-agent-image.ts for the commit,
# with $STATE_DIR/bin first on PATH and impd's token from $CREDENTIALS_DIRECTORY/imp-token in
# IMP_TOKEN, never in an argv. The build prints its progress to stderr and its result line, such as
# "agent-0123abc <digest> check passed", on stdout; the script prints that line after
# "agent-image-build: ". Inputs: REPO_URL, STATE_DIR, IMP_URL (impd's API), CREDENTIALS_DIRECTORY,
# PODMAN, the podman that reaches imp-host, BUN, the bun that runs the build, and SLEEP, the sleep
# that pauses between tries (default: the one on PATH).

# imp-host's image installs the CLI here (zgeoff/impz host/Dockerfile)
impz_in_container=/usr/local/bin/impz
pause="${SLEEP:-sleep}"
tries="${AGENT_IMAGE_WAIT_TRIES:-120}"

clone="$STATE_DIR/cloud"
if [ ! -d "$clone/.git" ]; then
  rm -rf "$clone"
  git clone -q --no-checkout "$REPO_URL" "$clone"
fi
git -C "$clone" fetch -q origin main

sha=$(git -C "$clone" log -1 --format=%H origin/main -- images/agent)
if [ -z "$sha" ]; then
  echo "agent-image-build: no commit on main changes images/agent; nothing to build"
  exit 0
fi
image="agent-$(git -C "$clone" rev-parse --short "$sha")"

failed="$STATE_DIR/failed/$sha"
if [ -f "$failed" ]; then
  echo "agent-image-build: the build of $image from $sha failed at $(cat "$failed"); remove $failed to build it again"
  exit 0
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT
try=1
last=
# root's home in imp-host, where impz finds impd's token: Podman reads a default HOME through this
# unit's mounts, which a mount namespace from before imp-host's container started leaves empty
until images=$("$PODMAN" exec -e HOME=/root imp-host impz image ls --json 2> "$err"); do
  if [ "$try" -ge "$tries" ]; then
    echo "agent-image-build: impd listed no images after $tries tries: $(cat "$err"); the next run tries again"
    exit 0
  fi
  if [ "$(cat "$err")" != "$last" ]; then
    last=$(cat "$err")
    echo "agent-image-build: waiting for impd, try $try: $last"
  fi
  try=$((try + 1))
  "$pause" 5
done
if jq -e --arg name "$image" 'any(.[]; .name == $name)' <<< "$images" > /dev/null; then
  echo "agent-image-build: impd holds $image, built from $sha; nothing to build"
  exit 0
fi

# leave_if_imp_host_changed <what failed>: exits 0, naming both container IDs, when imp-host's
# container is no longer $container
leave_if_imp_host_changed() {
  local now
  now=$("$PODMAN" container inspect --format '{{.Id}}' imp-host 2> /dev/null || echo none)
  if [ "$now" != "$container" ]; then
    echo "agent-image-build: $1 while imp-host went from container $container to $now; the next run builds $image again"
    exit 0
  fi
}

container=$("$PODMAN" container inspect --format '{{.Id}}' imp-host 2> /dev/null || echo none)
if [ "$container" = none ]; then
  echo "agent-image-build: imp-host went from the container that listed impd's images to none before the build of $image from $sha; the next run builds $image again"
  exit 0
fi
mkdir -p "$STATE_DIR/bin"
# read in the container, not with podman cp, which reads through this unit's mounts, where a mount
# namespace made before imp-host's container started shows none of the container's files
if ! mode=$("$PODMAN" exec imp-host stat -c %a "$impz_in_container") ||
  ! "$PODMAN" exec imp-host cat "$impz_in_container" > "$STATE_DIR/bin/impz.new"; then
  rm -f "$STATE_DIR/bin/impz.new"
  leave_if_imp_host_changed "the copy of imp's CLI failed"
  exit 1
fi
chmod "$mode" "$STATE_DIR/bin/impz.new"
mv "$STATE_DIR/bin/impz.new" "$STATE_DIR/bin/impz"
git -C "$clone" checkout -q -f --detach origin/main
token=$(cat "$CREDENTIALS_DIRECTORY/imp-token")

echo "agent-image-build: building $image from $sha"
status=0
result=$(cd "$clone" && PATH="$STATE_DIR/bin:$PATH" IMP_URL="$IMP_URL" IMP_TOKEN="$token" \
  "$BUN" scripts/build-agent-image.ts "$sha") || status=$?
if [ "$status" -ne 0 ]; then
  leave_if_imp_host_changed "the build of $image from $sha failed with status $status"
  mkdir -p "$STATE_DIR/failed"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$failed"
  echo "agent-image-build: the build of $image from $sha failed with status $status: $result; remove $failed to build it again" >&2
  exit 1
fi
echo "agent-image-build: $result"
