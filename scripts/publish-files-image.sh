#!/usr/bin/env bash
# Build the files image from the context that write-files-image-context.sh wrote, and push it to
# GHCR as ghcr.io/zgeoff/cloud-files:<commit> unless that tag is already published: the files image
# workflow's publish job runs it on main. It logs docker in to ghcr.io as GITHUB_ACTOR with GH_TOKEN
# on stdin, and builds on the distroless base that images/atc-gateway/versions.env pins. A
# published tag is immutable: it skips a tag the registry already holds, and pushes only when the
# registry confirms the tag is missing; any other lookup error stops the run. The outcome is a line
# in GITHUB_STEP_SUMMARY, with the digest that the stack config's files.image pins.
#
#   GH_TOKEN=… GITHUB_ACTOR=… GITHUB_SHA=… GITHUB_STEP_SUMMARY=… bash scripts/publish-files-image.sh <context>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" != 1 ]; then
  echo "usage: publish-files-image.sh <context>" >&2
  exit 2
fi
context="$1"
: "${GH_TOKEN:?set GH_TOKEN to the token that pushes to ghcr.io}"
: "${GITHUB_ACTOR:?set GITHUB_ACTOR to the user the token belongs to}"
: "${GITHUB_SHA:?set GITHUB_SHA to the commit the image is built from}"
: "${GITHUB_STEP_SUMMARY:?set GITHUB_STEP_SUMMARY to the file that records the image}"
if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "GITHUB_SHA must be a full commit hash: $GITHUB_SHA" >&2
  exit 1
fi

# shellcheck source=/dev/null
source images/atc-gateway/versions.env
ref="ghcr.io/zgeoff/cloud-files:$GITHUB_SHA"
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
# shellcheck disable=SC2153 # BASE_IMAGE comes from versions.env
docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$ref" "$context"
if lookup=$(docker manifest inspect "$ref" 2>&1); then
  echo "$ref: already published, not replaced" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
if ! grep -qiE 'no such manifest|manifest unknown' <<< "$lookup"; then
  echo "cannot tell whether $ref exists: $lookup" >&2
  exit 1
fi
docker push "$ref"
echo "$ref: $(docker inspect --format '{{index .RepoDigests 0}}' "$ref")" >> "$GITHUB_STEP_SUMMARY"
