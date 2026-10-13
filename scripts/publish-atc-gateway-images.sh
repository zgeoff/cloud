#!/usr/bin/env bash
# Build the atc-gateway and backup images at the pins in deploy/atc-gateway/versions.env and push
# each one to GHCR unless its tag is already published: the atc-gateway images workflow's publish
# job runs it on a manual run with push: true. It logs docker in to ghcr.io as GITHUB_ACTOR with
# GH_TOKEN on stdin, fetches and checks the pinned atc release into context/ at the repo root
# (fetch-atc-release.sh), and builds both images. A published tag is immutable: it skips a tag the
# registry already holds, and pushes only when the registry confirms the tag is missing; any other
# lookup error stops the run. Each image's outcome is a line in GITHUB_STEP_SUMMARY.
#
#   GH_TOKEN=… GITHUB_ACTOR=… GITHUB_STEP_SUMMARY=… bash scripts/publish-atc-gateway-images.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${GH_TOKEN:?set GH_TOKEN to the token that pushes to ghcr.io}"
: "${GITHUB_ACTOR:?set GITHUB_ACTOR to the user the token belongs to}"
: "${GITHUB_STEP_SUMMARY:?set GITHUB_STEP_SUMMARY to the file that records each image}"

# shellcheck source=/dev/null
source deploy/atc-gateway/versions.env
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
bash scripts/fetch-atc-release.sh context
cp deploy/atc-gateway/Dockerfile context/
gateway="ghcr.io/zgeoff/atc-gateway:$GATEWAY_IMAGE_TAG"
backup="ghcr.io/zgeoff/atc-gateway-backup:$BACKUP_IMAGE_TAG"
docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$gateway" context
docker build --build-arg "RESTIC_IMAGE=$RESTIC_IMAGE" -t "$backup" deploy/atc-gateway/backup
# a published tag is immutable: skip it, and push only when the registry confirms the tag is
# missing; any other lookup error stops the run
for ref in "$gateway" "$backup"; do
  if lookup=$(docker manifest inspect "$ref" 2>&1); then
    echo "$ref: already published, not replaced" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi
  if ! grep -qiE 'no such manifest|manifest unknown' <<< "$lookup"; then
    echo "cannot tell whether $ref exists: $lookup" >&2
    exit 1
  fi
  docker push "$ref"
  echo "$ref: $(docker inspect --format '{{index .RepoDigests 0}}' "$ref")" >> "$GITHUB_STEP_SUMMARY"
done
