#!/usr/bin/env bash
# The files image test: it writes the build context with scripts/write-files-image-context.sh,
# builds the image on the pinned distroless base under a tag that carries a random per-run id, runs
# the files-image suites (images/files/test-files-image.sh) with FILES_IMAGE and FILES_RUN set, and
# removes the image and the context after. When the build fails it prints the build log and
# exits 1. The files image workflow runs it as `bun run test:files-image`, after `bun install`.
#
#   bash images/files/run-image-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# sets BASE_IMAGE, among the pins
# shellcheck source=/dev/null
source images/atc-gateway/versions.env
FILES_RUN="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
FILES_IMAGE="cloud-files:test-$FILES_RUN"
export FILES_RUN FILES_IMAGE
work="$(mktemp -d)"
trap 'docker rmi -f "$FILES_IMAGE" > /dev/null 2>&1 || true; rm -rf "$work" || true' EXIT
# shellcheck disable=SC2153 # BASE_IMAGE comes from versions.env
if ! {
  bash scripts/write-files-image-context.sh "$work/context" &&
    docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$FILES_IMAGE" "$work/context"
} > "$work/build.log" 2>&1; then
  echo "FAIL the files image did not build"
  sed 's/^/    /' "$work/build.log"
  exit 1
fi
echo "built $FILES_IMAGE"
bash scripts/run-shell-suites.sh files-image
