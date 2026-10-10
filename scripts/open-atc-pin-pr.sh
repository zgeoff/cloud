#!/usr/bin/env bash
# Open or update the pull request that pins an atc release in the agent image. Run it from the
# root of a zgeoff/cloud clone whose origin is zgeoff/cloud, with gh signed in to a token that may
# push to it and open pull requests, and a git identity for the commit. atc's release job runs it
# after each release with the release bot's token and the SHA256SUMS it just published:
#
#   bash scripts/open-atc-pin-pr.sh <version> <SHA256SUMS file>
#
# It builds the atc-pin/agent-image branch from origin's main with pin-agent-atc.sh, and
# force-pushes it with a lease on the branch it read. One pull request carries the newest release:
# a later release replaces the branch and the pull request's title and body, and first turns off
# that pull request's auto-merge, so the new pin waits for its own checks. The agent image
# workflow turns auto-merge back on once those pass.
#
# It stops, with no push and no pull request, when main already pins the release or a newer one,
# and when the branch already holds the release or a newer one, as when an older release's job
# finishes last.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: open-atc-pin-pr.sh <version> <SHA256SUMS file>" >&2
  exit 2
fi
version="$1"
sums="$2"
repo=zgeoff/cloud
branch=atc-pin/agent-image
title="chore: pin atc $version in the agent image"
body="Pins atc $version in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes."

git fetch -q origin main

# the branch's current commit, for the push's lease; empty when the branch does not exist
lease=""
status=0
git ls-remote --exit-code --heads origin "refs/heads/$branch" > /dev/null || status=$?
case "$status" in
  0)
    git fetch -q origin "refs/heads/$branch"
    lease="$(git rev-parse FETCH_HEAD)"
    branch_version="$(git show FETCH_HEAD:images/agent/Dockerfile | sed -n 's/^ARG ATC_VERSION=//p')"
    if [ "$(printf '%s\n' "$branch_version" "$version" | sort -V | tail -1)" = "$branch_version" ]; then
      echo "$branch already pins atc $branch_version, which is not older than $version"
      exit 0
    fi
    ;;
  2) ;;
  *) exit "$status" ;;
esac

git checkout -q -B "$branch" origin/main
bash scripts/pin-agent-atc.sh "$version" "$sums"
if git diff --quiet; then
  exit 0
fi

prs="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,autoMergeRequest)"
number="$(jq -r '.[0].number // empty' <<< "$prs")"
if [ -n "$number" ] && [ "$(jq -r '.[0].autoMergeRequest != null' <<< "$prs")" = true ]; then
  gh pr merge "$number" --repo "$repo" --disable-auto >&2
fi

git commit -qam "$title"
git push -q --force-with-lease="refs/heads/$branch:$lease" origin "HEAD:refs/heads/$branch"

if [ -n "$number" ]; then
  gh pr edit "$number" --repo "$repo" --title "$title" --body "$body"
else
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body "$body"
fi
