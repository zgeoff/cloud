#!/usr/bin/env bash
# Fetch the pinned atc release asset into a build context and check it twice: against
# the release's SHA256SUMS and against the pin in deploy/atc-gateway/versions.env.
# Usage: scripts/fetch-atc-release.sh <context-dir>
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"
out="${1:?usage: fetch-atc-release.sh <context-dir>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download "$ATC_RELEASE" -R zgeoff/atc -p "$ATC_ASSET" -p SHA256SUMS -D "$work"
(cd "$work" && grep " $ATC_ASSET\$" SHA256SUMS | sha256sum -c -)
echo "$ATC_ASSET_SHA256  $work/$ATC_ASSET" | sha256sum -c -

mkdir -p "$out"
install -m 0555 "$work/$ATC_ASSET" "$out/atc-gateway"
