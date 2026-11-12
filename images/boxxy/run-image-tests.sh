#!/usr/bin/env bash
# The boxxy image test: it writes the build context with scripts/write-boxxy-image-context.sh,
# builds the image on the pinned distroless base under a tag that carries a random per-run id, runs
# the boxxy-image suite (images/boxxy/test-boxxy-image.sh) with BOXXY_IMAGE and BOXXY_RUN set, and
# removes the image and the context after. When the build fails it prints the build log and
# exits 1. The boxxy image workflow runs it as `bun run test:boxxy-image`, after `bun install`.
#
#   bash images/boxxy/run-image-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# sets BASE_IMAGE, among the pins
# shellcheck source=/dev/null
source images/atc-gateway/versions.env
BOXXY_RUN="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
BOXXY_IMAGE="cloud-boxxy:test-$BOXXY_RUN"
export BOXXY_RUN BOXXY_IMAGE
work="$(mktemp -d)"
trap 'docker rmi -f "$BOXXY_IMAGE" > /dev/null 2>&1 || true; rm -rf "$work" || true' EXIT
# shellcheck disable=SC2153 # BASE_IMAGE comes from versions.env
if ! {
  bash scripts/write-boxxy-image-context.sh "$work/context" &&
    docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$BOXXY_IMAGE" "$work/context"
} > "$work/build.log" 2>&1; then
  echo "FAIL the boxxy image did not build"
  sed 's/^/    /' "$work/build.log"
  exit 1
fi
echo "built $BOXXY_IMAGE"
bash scripts/run-shell-suites.sh boxxy-image
