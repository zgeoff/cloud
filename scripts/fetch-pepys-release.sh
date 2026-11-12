#!/usr/bin/env bash
# Fetch the pinned pepys host binary into a build context and check it twice: against the
# release's SHA256SUMS and against the pin in images/pepys/versions.env.
# Usage: scripts/fetch-pepys-release.sh <context-dir>
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo/images/pepys/versions.env"
out="${1:?usage: fetch-pepys-release.sh <context-dir>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download "$PEPYS_RELEASE" -R zgeoff/pepys -p "$PEPYS_HOST_ASSET" -p SHA256SUMS -D "$work"
(cd "$work" && grep " $PEPYS_HOST_ASSET\$" SHA256SUMS | sha256sum -c -)
echo "$PEPYS_HOST_ASSET_SHA256  $work/$PEPYS_HOST_ASSET" | sha256sum -c -

mkdir -p "$out"
install -m 0555 "$work/$PEPYS_HOST_ASSET" "$out/pepys-host"
