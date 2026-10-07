# shellcheck shell=bash
# with_fixture_images <command...>: builds the atc-gateway image from the pinned, checked
# release (scripts/fetch-atc-release.sh) and the backup image from the pinned restic base,
# as the fixture suites need them, under tags that carry a random per-run id. It then runs
# the command with FIXTURE_RUN (that id), FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE
# in its environment, removes both images, and returns the command's exit status. When
# a build fails it prints "FAIL the images did not build …" and the build log indented to
# stdout, runs nothing, and returns 1.
#
# Run as a script, it calls with_fixture_images with its arguments, so the Docker test
# files share one build:
#
#   bash scripts/test-lib/with-fixture-images.sh bash scripts/test-lib/test-run-backup.sh
with_fixture_images() (
  set -euo pipefail
  local repo work status=0
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # sets BASE_IMAGE and RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/deploy/atc-gateway/versions.env"
  FIXTURE_RUN="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  FIXTURE_GATEWAY_IMAGE="atc-gateway:fixture-$FIXTURE_RUN"
  FIXTURE_BACKUP_IMAGE="atc-gateway-backup:fixture-$FIXTURE_RUN"
  export FIXTURE_RUN FIXTURE_GATEWAY_IMAGE FIXTURE_BACKUP_IMAGE
  work="$(mktemp -d)"
  trap 'docker rmi -f "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" > /dev/null 2>&1 || true; rm -rf "$work" || true' EXIT
  # shellcheck disable=SC2153 # BASE_IMAGE and RESTIC_IMAGE come from versions.env
  if ! {
    "$repo/scripts/fetch-atc-release.sh" "$work/context" &&
      cp "$repo/deploy/atc-gateway/Dockerfile" "$work/context/" &&
      docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$FIXTURE_GATEWAY_IMAGE" "$work/context" &&
      docker build -q --build-arg "RESTIC_IMAGE=$RESTIC_IMAGE" -t "$FIXTURE_BACKUP_IMAGE" \
        "$repo/deploy/atc-gateway/backup"
  } > "$work/build.log" 2>&1; then
    echo "FAIL the images did not build from the pinned, checked binary and pinned bases"
    sed 's/^/    /' "$work/build.log"
    return 1
  fi
  echo "built $FIXTURE_GATEWAY_IMAGE and $FIXTURE_BACKUP_IMAGE"
  "$@" || status=$?
  return "$status"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  with_fixture_images "$@"
fi
