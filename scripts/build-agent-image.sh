#!/usr/bin/env bash
# Build and check the agent image for one commit on main, in one command. Run it from a zgeoff/cloud
# clone, on a machine whose imp CLI calls the geoffcloud host with a manage-scope token:
#
#   bash scripts/build-agent-image.sh [--keep] [<commit on main>]
#
# The commit defaults to origin/main's head, read after a fetch. It builds images/agent from a git
# archive of that commit, so the clone's working tree never reaches the image, and names the image
# agent-<short sha>. It then creates the imp agent-check-<short sha> from the image, runs that
# commit's scripts/check-agent-image.sh on it, and removes the imp. The last line on stdout names
# the image, its digest and the check's result. A failed check removes the image unless --keep
# is given, and every failure exits 1.
#
# imp image build prints no progress off a terminal, so the build runs quietly for several minutes.
# AGENT_IMAGE_BUILD_TIMEOUT (a `timeout` duration, 45m by default) stops a build that hangs; impd
# can still finish that build afterwards, so read `imp image ls` before a retry.
set -euo pipefail

keep=0
commit=origin/main
case "$#:${1:-}" in
  0:) ;;
  1:--keep) keep=1 ;;
  1:-*) commit="" ;;
  1:*) commit="$1" ;;
  2:--keep) keep=1 commit="$2" ;;
  *) commit="" ;;
esac
if [ -z "$commit" ] || [[ "$commit" == -* ]]; then
  echo "usage: build-agent-image.sh [--keep] [<commit on main>]" >&2
  exit 2
fi

git fetch -q origin main
sha="$(git rev-parse --verify "$commit^{commit}")"
if ! git merge-base --is-ancestor "$sha" origin/main; then
  echo "$sha is not on origin/main: build only a commit that main holds" >&2
  exit 1
fi
short="$(git rev-parse --short "$sha")"
image="agent-$short"
check="agent-check-$short"

if imp image ls --json | jq -e --arg n "$image" 'any(.[]; .name == $n)' > /dev/null; then
  echo "image $image already exists: remove it with imp image rm, or build another commit" >&2
  exit 1
fi
if imp ls --json | jq -e --arg n "$check" 'any(.[]; .name == $n)' > /dev/null; then
  echo "imp $check already exists: remove it with imp rm first" >&2
  exit 1
fi

work="$(mktemp -d)"
created=0
teardown() {
  if [ "$created" = 1 ]; then imp rm "$check" >&2 || true; fi
  rm -rf "$work"
}
trap teardown EXIT

mkdir "$work/src"
git archive "$sha" images/agent scripts | tar -x -C "$work/src"

timeout="${AGENT_IMAGE_BUILD_TIMEOUT:-45m}"
echo "building $image from $sha; imp image build shows no progress off a terminal" >&2
status=0
timeout "$timeout" imp image build "$work/src/images/agent" --name "$image" >&2 || status=$?
if [ "$status" = 124 ]; then
  echo "imp image build did not finish within $timeout; impd may still finish $image, so read imp image ls before a retry" >&2
  exit 1
elif [ "$status" != 0 ]; then
  echo "imp image build failed for $image" >&2
  exit 1
fi
digest="$(imp image ls --json | jq -r --arg n "$image" '.[] | select(.name == $n) | .digest')"

echo "checking $image on a fresh imp, $check" >&2
imp new "$check" --image "$image" >&2
created=1
result=passed
bash "$work/src/scripts/check-agent-image.sh" --imp "$check" >&2 || result=failed
imp rm "$check" >&2
created=0

if [ "$result" = passed ]; then
  echo "$image $digest check passed"
elif [ "$keep" = 1 ]; then
  echo "$image $digest check failed; kept the image"
  exit 1
else
  imp image rm "$image" >&2
  echo "$image check failed; removed the image"
  exit 1
fi
