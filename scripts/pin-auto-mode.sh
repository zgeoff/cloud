#!/usr/bin/env bash
# Pin an auto-mode release in the agent image: set images/agent/Dockerfile's ARG AUTO_MODE_VERSION
# to <version> and ARG AUTO_MODE_SHA256 to the sha256 of that release's npm tarball, and change
# nothing else. Run it from the root of a zgeoff/cloud checkout. bump-release.sh runs it with the
# tarball and the dist.integrity it read from the npm registry; a person runs it the same way:
#
#   curl -fsSL -o /tmp/auto-mode.tgz "https://registry.npmjs.org/auto-mode/-/auto-mode-$VERSION.tgz"
#   bash scripts/pin-auto-mode.sh "$VERSION" /tmp/auto-mode.tgz \
#     "$(npm view "auto-mode@$VERSION" dist.integrity)"
#
# The tarball must match <integrity>, npm's sha512 of it, and its package.json must name
# <version>. A pin that already holds <version> and its sum, or a newer version, stays as it is. A
# pin that holds <version> with another sum fails: npm never changes a published tarball, so a
# different sum needs a person. The image build checks the downloaded tarball against the pinned
# sum.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: pin-auto-mode.sh <version> <tarball> <integrity>" >&2
  exit 2
fi
version="$1"
tarball="$2"
integrity="$3"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "not a release version: '$version'" >&2
  exit 2
fi
if [[ ! "$integrity" =~ ^sha512-[A-Za-z0-9+/]{86}==$ ]]; then
  echo "not a sha512 integrity: '$integrity'" >&2
  exit 2
fi

dockerfile=images/agent/Dockerfile
if [ ! -f "$dockerfile" ]; then
  echo "$dockerfile is missing: run this from the root of a zgeoff/cloud checkout" >&2
  exit 1
fi

want="$(base64 -d <<< "${integrity#sha512-}" | od -An -tx1 | tr -d ' \n')"
got="$(sha512sum "$tarball" | cut -d' ' -f1)"
if [ "$got" != "$want" ]; then
  echo "the tarball does not match $integrity" >&2
  exit 1
fi
packaged="$(tar -xzOf "$tarball" package/package.json | jq -r .version)"
if [ "$packaged" != "$version" ]; then
  echo "the tarball holds auto-mode $packaged, not $version" >&2
  exit 1
fi
sum="$(sha256sum "$tarball" | cut -d' ' -f1)"

for arg in AUTO_MODE_VERSION AUTO_MODE_SHA256; do
  count="$(grep -c "^ARG $arg=" "$dockerfile" || true)"
  if [ "$count" != 1 ]; then
    echo "$dockerfile has $count ARG $arg= lines, want 1" >&2
    exit 1
  fi
done
pinned_version="$(sed -n 's/^ARG AUTO_MODE_VERSION=//p' "$dockerfile")"
pinned_sum="$(sed -n 's/^ARG AUTO_MODE_SHA256=//p' "$dockerfile")"

if [ "$pinned_version" = "$version" ]; then
  if [ "$pinned_sum" != "$sum" ]; then
    echo "auto-mode $version is pinned with sum $pinned_sum, but the tarball's is $sum" >&2
    exit 1
  fi
  echo "auto-mode $version is already pinned"
  exit 0
fi
# a pin never moves back to an older release
if [ "$(printf '%s\n' "$pinned_version" "$version" | sort -V | tail -1)" = "$pinned_version" ]; then
  echo "auto-mode $pinned_version is pinned, which is newer than $version"
  exit 0
fi

# write beside the Dockerfile, then rename over it, so a failed write leaves the pin as it was
sed -e "s/^ARG AUTO_MODE_VERSION=.*/ARG AUTO_MODE_VERSION=$version/" \
  -e "s/^ARG AUTO_MODE_SHA256=.*/ARG AUTO_MODE_SHA256=$sum/" "$dockerfile" > "$dockerfile.new"
chmod --reference="$dockerfile" "$dockerfile.new"
mv "$dockerfile.new" "$dockerfile"
echo "pinned auto-mode $version: $sum"
