# shellcheck shell=bash
# Build and check the agent image of the newest commit on main that changes images/agent, when impd
# holds no image of that name yet. The script keeps a clone of $REPO_URL in $STATE_DIR/cloud and
# fetches its main without a credential. The image is agent-<short sha> of that commit, as
# scripts/build-agent-image.ts names it, and the script skips the run when impd lists that name,
# when no commit on main changes images/agent, or when a build of that commit failed before. Each
# failed build leaves its time in $STATE_DIR/failed/<sha>, so a broken commit is built once, not at
# every run; removing that file builds it again at the next run.
#
# To build, it copies imp's CLI out of the imp-host container, so the CLI always matches the impd it
# calls, checks out main's head, and runs that head's scripts/build-agent-image.ts for the commit,
# with $STATE_DIR/bin first on PATH and impd's token from $CREDENTIALS_DIRECTORY/imp-token in
# IMP_TOKEN, never in an argv. The build prints its progress to stderr and its result line, such as
# "agent-0123abc <digest> check passed", on stdout; the script prints that line after
# "agent-image-build: ". Inputs: REPO_URL, STATE_DIR, IMP_URL (impd's API), CREDENTIALS_DIRECTORY,
# PODMAN, the podman that reaches imp-host, and BUN, the bun that runs the build.

# imp-host's image installs the CLI here (zgeoff/impz host/Dockerfile)
impz_in_container=/usr/local/bin/impz

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

images=$("$PODMAN" exec imp-host impz image ls --json)
if jq -e --arg name "$image" 'any(.[]; .name == $name)' <<< "$images" > /dev/null; then
  echo "agent-image-build: impd holds $image, built from $sha; nothing to build"
  exit 0
fi

mkdir -p "$STATE_DIR/bin"
"$PODMAN" cp "imp-host:$impz_in_container" "$STATE_DIR/bin/impz"
git -C "$clone" checkout -q -f --detach origin/main
token=$(cat "$CREDENTIALS_DIRECTORY/imp-token")

echo "agent-image-build: building $image from $sha"
status=0
result=$(cd "$clone" && PATH="$STATE_DIR/bin:$PATH" IMP_URL="$IMP_URL" IMP_TOKEN="$token" \
  "$BUN" scripts/build-agent-image.ts "$sha") || status=$?
if [ "$status" -ne 0 ]; then
  mkdir -p "$STATE_DIR/failed"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$failed"
  echo "agent-image-build: the build of $image from $sha failed with status $status: $result; remove $failed to build it again" >&2
  exit 1
fi
echo "agent-image-build: $result"
