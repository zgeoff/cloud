#!/usr/bin/env bash
# Pin an atc release in the agent image: set images/agent/Dockerfile's ARG ATC_VERSION to
# <version> and ARG ATC_SHA256 to atc-linux-x64's sum in that release's SHA256SUMS, and change
# nothing else. Run it from the root of a zgeoff/cloud checkout. atc's release job runs it with
# the SHA256SUMS it just published; a person runs it after downloading that file:
#
#   gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p SHA256SUMS -D /tmp/atc-sums
#   bash scripts/pin-agent-atc.sh "$VERSION" /tmp/atc-sums/SHA256SUMS
#
# A pin that already holds <version> and its sum, or a newer version, stays as it is. A pin that
# holds <version> with another sum fails: a release's assets never change, so a different sum
# needs a person.
# The image build checks the downloaded binary against the pinned sum.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: pin-agent-atc.sh <version> <SHA256SUMS file>" >&2
  exit 2
fi
version="$1"
sums="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "not a release version: '$version'" >&2
  exit 2
fi

dockerfile=images/agent/Dockerfile
if [ ! -f "$dockerfile" ]; then
  echo "$dockerfile is missing: run this from the root of a zgeoff/cloud checkout" >&2
  exit 1
fi

lines="$(grep -E '[[:space:]]\*?atc-linux-x64$' "$sums" || true)"
count="$(grep -c . <<< "$lines" || true)"
if [ "$count" != 1 ]; then
  echo "SHA256SUMS has $count atc-linux-x64 lines, want 1" >&2
  exit 1
fi
if [[ ! "$lines" =~ ^([0-9a-f]{64})\ [\ *]atc-linux-x64$ ]]; then
  echo "SHA256SUMS's atc-linux-x64 line holds no sha256 sum" >&2
  exit 1
fi
sum="${BASH_REMATCH[1]}"

for arg in ATC_VERSION ATC_SHA256; do
  count="$(grep -c "^ARG $arg=" "$dockerfile" || true)"
  if [ "$count" != 1 ]; then
    echo "$dockerfile has $count ARG $arg= lines, want 1" >&2
    exit 1
  fi
done
pinned_version="$(sed -n 's/^ARG ATC_VERSION=//p' "$dockerfile")"
pinned_sum="$(sed -n 's/^ARG ATC_SHA256=//p' "$dockerfile")"

if [ "$pinned_version" = "$version" ]; then
  if [ "$pinned_sum" != "$sum" ]; then
    echo "atc $version is pinned with sum $pinned_sum, but SHA256SUMS lists $sum" >&2
    exit 1
  fi
  echo "atc $version is already pinned"
  exit 0
fi
# a release job that finishes after a newer release's job must not move the pin back
if [ "$(printf '%s\n' "$pinned_version" "$version" | sort -V | tail -1)" = "$pinned_version" ]; then
  echo "atc $pinned_version is pinned, which is newer than $version"
  exit 0
fi

# write beside the Dockerfile, then rename over it, so a failed write leaves the pin as it was
sed -e "s/^ARG ATC_VERSION=.*/ARG ATC_VERSION=$version/" \
  -e "s/^ARG ATC_SHA256=.*/ARG ATC_SHA256=$sum/" "$dockerfile" > "$dockerfile.new"
chmod --reference="$dockerfile" "$dockerfile.new"
mv "$dockerfile.new" "$dockerfile"
echo "pinned atc $version: $sum"
