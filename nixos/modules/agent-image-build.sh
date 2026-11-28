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
# Each run that learns the outcome for the newest commit writes it to node-exporter's textfile
# collector, in $TEXTFILE_DIR/agent_image_build.prom: agent_image_build_failed{commit="<sha>"} is 1
# while a failed record for that commit stops its build and the agent alias is not on its image,
# and 0 once impd holds the image, or the build passes. A run that starts a build, or the move of the alias, writes 0 first, so a retry
# that passes never holds the alert up, and a run whose script fails after the alias moved to the
# image leaves no record and writes 0, because the alias is on the newest commit's image. A newer
# commit has no record, so the metric follows the newest commit and the
# AgentImageBuildFailed alert resolves on its own once a build passes. A run that exits before it
# knows the outcome leaves the file as it was.
#
# An image that impd holds pinned, which only a passed check does, but without the agent alias, as
# when its build ran on an impd without image aliases, gets no build: the script runs
# scripts/promote-agent-image.ts for the image, with the same CLI and token, and prints that script's
# result line. A failed move leaves a record like a failed build.
#
# To build, it copies imp's CLI out of the imp-host container with its mode, so the CLI always
# matches the impd it calls, checks out main's head, and runs that head's
# scripts/build-agent-image.ts for the commit,
# with $STATE_DIR/bin first on PATH and impd's token from $CREDENTIALS_DIRECTORY/imp-token in
# IMP_TOKEN, never in an argv. The build prints its progress to stderr and its result line, such as
# "agent-0123abc <digest> check passed", on stdout; the script prints that line after
# "agent-image-build: ". Inputs: REPO_URL, STATE_DIR, IMP_URL (impd's API), CREDENTIALS_DIRECTORY,
# PODMAN, the podman that reaches imp-host, BUN, the bun that runs the build, TEXTFILE_DIR, the
# directory of node-exporter's textfile collector, and SLEEP, the sleep that pauses between tries
# (default: the one on PATH).

# imp-host's image installs the CLI here (zgeoff/impz host/Dockerfile)
impz_in_container=/usr/local/bin/impz
pause="${SLEEP:-sleep}"
tries="${AGENT_IMAGE_WAIT_TRIES:-120}"

# write_metric <0 or 1>: records whether the build of the newest commit has failed. The file is
# written in $STATE_DIR, which only root can write, and moved into $TEXTFILE_DIR in one rename:
# $TEXTFILE_DIR belongs to another account, which could swap a file there between its creation and
# a write that opens it again by name. A write that fails prints a warning and leaves the run's
# outcome alone.
write_metric() {
  local tmp
  if ! tmp=$(mktemp -p "$STATE_DIR" .agent_image_build.XXXXXX 2> /dev/null); then
    echo "agent-image-build: warning: cannot write the metric under $STATE_DIR" >&2
    return 0
  fi
  cat > "$tmp" << EOF
# HELP agent_image_build_failed 1 while the build of the newest commit that changes images/agent has failed and the agent alias stays on an older image, 0 otherwise.
# TYPE agent_image_build_failed gauge
agent_image_build_failed{commit="$sha"} $1
EOF
  if ! { chmod 0644 "$tmp" && mv -T "$tmp" "$TEXTFILE_DIR/agent_image_build.prom" 2> /dev/null; }; then
    rm -f "$tmp"
    echo "agent-image-build: warning: cannot write the metric to $TEXTFILE_DIR" >&2
  fi
}

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
# the images that switch-agent-image pinned with no passing check: a pin does not show a check for
# them. A file that cannot be read counts every pinned image as one of them.
retention="$HOME/.local/state/cloud/agent-image-retention.json"
if [ ! -e "$retention" ]; then
  switch_only='[]'
elif ! switch_only=$(jq -c '[.switchOnlyImages[]? | strings]' "$retention" 2> /dev/null); then
  switch_only='null'
fi
# absent: no such image; aliased: it holds the agent alias; unaliased: it passed its check, which
# pins it, and lacks the alias, as when its build ran on an impd without image aliases; unchecked:
# it is not pinned, or only a switch pinned it
state=$(jq -r --arg name "$image" --argjson switchOnly "$switch_only" '
  [.[] | select(.name == $name)] |
  if length == 0 then "absent"
  elif ((.[0].aliases // []) | index("agent")) != null then "aliased"
  elif .[0].pinned == true and $switchOnly != null and (($switchOnly | index($name)) == null)
  then "unaliased"
  else "unchecked" end' <<< "$images")
# the alias on this commit's image outranks a failed record, which a run whose lookup of the alias
# failed after the alias moved leaves behind
if [ "$state" = aliased ]; then
  write_metric 0
  echo "agent-image-build: impd holds $image, built from $sha; nothing to build"
  exit 0
fi
if [ -f "$failed" ]; then
  write_metric 1
  echo "agent-image-build: the build of $image from $sha failed at $(cat "$failed"); remove $failed to build it again"
  exit 0
fi
if [ "$state" = unchecked ]; then
  write_metric 0
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

# an image that passed its check without the alias needs the move only, not a build
if [ "$state" = unaliased ]; then
  doing="moving the agent alias to $image"
  what="the move of the agent alias to $image from $sha"
  again="try it again"
  script=(scripts/promote-agent-image.ts "$image")
else
  doing="building $image from $sha"
  what="the build of $image from $sha"
  again="build it again"
  script=(scripts/build-agent-image.ts "$sha")
fi

# a failed record for this commit is gone, or the commit is new, so the metric stops saying the
# commit failed while the build runs, and a retry that passes never holds the alert up
write_metric 0
echo "agent-image-build: $doing"
status=0
result=$(cd "$clone" && PATH="$STATE_DIR/bin:$PATH" IMP_URL="$IMP_URL" IMP_TOKEN="$token" \
  "$BUN" "${script[@]}") || status=$?
if [ "$status" -ne 0 ]; then
  leave_if_imp_host_changed "$what failed with status $status"
  # A failure after the alias moved, such as the unpinning of old images, leaves the agent alias on
  # this image: no build is left to retry, so the run keeps no record and reports no failed build.
  if after=$("$PODMAN" exec -e HOME=/root imp-host impz image ls --json 2> /dev/null) &&
    [ "$(jq -r --arg name "$image" '[.[] | select(.name == $name and ((.aliases // []) | index("agent")) != null)] | length' <<< "$after" 2> /dev/null)" = 1 ]; then
    write_metric 0
    echo "agent-image-build: $what failed with status $status after the agent alias moved to $image: $result" >&2
    exit 1
  fi
  mkdir -p "$STATE_DIR/failed"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$failed"
  write_metric 1
  echo "agent-image-build: $what failed with status $status: $result; remove $failed to $again" >&2
  exit 1
fi
write_metric 0
echo "agent-image-build: $result"
