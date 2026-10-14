#!/usr/bin/env bash
# Pin an atc release everywhere cloud runs atc: the agent image, through pin-agent-atc.sh; the
# host's atc daemon, in nixos/packages/atc.nix; and the atc-gateway images, in
# images/atc-gateway/versions.env. Each pin takes its asset's sum from the release's SHA256SUMS:
# atc-linux-x64 for the agent image and the daemon, and versions.env's ATC_ASSET for the gateway.
# Run it from the root of a zgeoff/cloud checkout. The release check runs it with the SHA256SUMS
# it downloaded (scripts/bump-release.sh):
#
#   bash scripts/pin-atc.sh <version> <SHA256SUMS file>
#
# Each pin follows pin-agent-atc.sh's rules on its own: a pin that holds <version> and its sum, or
# a newer version, stays as it is, and a pin that holds <version> with another sum fails.
# versions.env's GATEWAY_IMAGE_TAG moves with ATC_RELEASE, because a published gateway tag is
# never replaced. The daemon and gateway pins are checked before the agent image pin writes, so a
# failure of any check changes no file.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: pin-atc.sh <version> <SHA256SUMS file>" >&2
  exit 2
fi
version="$1"
sums="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "not a release version: '$version'" >&2
  exit 2
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nix=nixos/packages/atc.nix
env=images/atc-gateway/versions.env
for file in "$nix" "$env"; do
  if [ ! -f "$file" ]; then
    echo "$file is missing: run this from the root of a zgeoff/cloud checkout" >&2
    exit 1
  fi
done

# read_sum <asset>: prints the asset's sum from SHA256SUMS, or fails unless exactly one line names it
read_sum() {
  local lines count
  lines="$(grep -E "[[:space:]]\*?$1\$" "$sums" || true)"
  count="$(grep -c . <<< "$lines" || true)"
  if [ "$count" != 1 ]; then
    echo "SHA256SUMS has $count $1 lines, want 1" >&2
    exit 1
  fi
  if [[ ! "$lines" =~ ^([0-9a-f]{64})\ [\ *]"$1"$ ]]; then
    echo "SHA256SUMS's $1 line holds no sha256 sum" >&2
    exit 1
  fi
  echo "${BASH_REMATCH[1]}"
}

# read_line <file> <sed pattern>: prints what the one line matching the pattern captures, or
# fails unless exactly one line matches
read_line() {
  local count
  count="$(sed -nE "s|$2|\1|p" "$1" | grep -c . || true)"
  if [ "$count" != 1 ]; then
    echo "$1 has $count lines that match '$2', want 1" >&2
    exit 1
  fi
  sed -nE "s|$2|\1|p" "$1"
}

# needs_pin <file> <pinned version> <pinned sum> <sum>: exits 0 when the file needs <version>,
# and 1 when it already holds <version> or a newer release; fails on <version> with another sum
needs_pin() {
  if [ "$2" = "$version" ]; then
    if [ "$3" != "$4" ]; then
      echo "$1 pins atc $version with sum $3, but SHA256SUMS lists $4" >&2
      exit 1
    fi
    echo "$1 already pins atc $version"
    return 1
  fi
  if [ "$(printf '%s\n' "$2" "$version" | sort -V | tail -1)" = "$2" ]; then
    echo "$1 pins atc $2, which is newer than $version"
    return 1
  fi
}

# write <file> <sed script>: rewrites the file beside itself, then renames it over the original
write() {
  sed -E "$2" "$1" > "$1.new"
  chmod --reference="$1" "$1.new"
  mv "$1.new" "$1"
}

daemon_sum="$(read_sum atc-linux-x64)"
asset="$(read_line "$env" '^ATC_ASSET=(.*)$')"
gateway_sum="$(read_sum "$asset")"
nix_version="$(read_line "$nix" '^  version = "(.*)";$')"
nix_sum="$(read_line "$nix" '^  sha256 = "(.*)";$')"
env_version="$(read_line "$env" '^ATC_RELEASE=@zgeoff/atc@(.*)$')"
env_sum="$(read_line "$env" '^ATC_ASSET_SHA256=(.*)$')"
read_line "$env" '^GATEWAY_IMAGE_TAG=(.*)$' > /dev/null

pin_nix=false
pin_env=false
if needs_pin "$nix" "$nix_version" "$nix_sum" "$daemon_sum"; then pin_nix=true; fi
if needs_pin "$env" "$env_version" "$env_sum" "$gateway_sum"; then pin_env=true; fi

bash "$here/pin-agent-atc.sh" "$version" "$sums"

if [ "$pin_nix" = true ]; then
  write "$nix" "s/^  version = \".*\";\$/  version = \"$version\";/; s/^  sha256 = \".*\";\$/  sha256 = \"$daemon_sum\";/"
  echo "pinned atc $version in $nix: $daemon_sum"
fi
if [ "$pin_env" = true ]; then
  write "$env" "s/^ATC_RELEASE=.*\$/ATC_RELEASE=@zgeoff\/atc@$version/; s/^ATC_ASSET_SHA256=.*\$/ATC_ASSET_SHA256=$gateway_sum/; s/^GATEWAY_IMAGE_TAG=.*\$/GATEWAY_IMAGE_TAG=$version/"
  echo "pinned atc $version in $env: $gateway_sum"
fi
