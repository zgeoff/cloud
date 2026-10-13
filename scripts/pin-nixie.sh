#!/usr/bin/env bash
# Pin a nixie release in the stack config: set infra/Pulumi.prod.yaml's nixie image and nixie-web
# image to <version>'s tag and the digests that the release notes list under `## Images`, and
# change nothing else. Run it from the root of a zgeoff/cloud checkout. The release check runs it
# with the notes it read (scripts/bump-release.sh); a person runs it after saving them:
#
#   gh release view "v$VERSION" -R zgeoff/nixie --json body -q .body > /tmp/nixie-notes.md
#   bash scripts/pin-nixie.sh "$VERSION" /tmp/nixie-notes.md
#
# The rules follow pin-agent-atc.sh's: an image that already holds <version> and its digest, or a
# newer version, stays as it is, and one that holds <version> with another digest fails, because a
# release's images never change. It checks both images before it writes, so a failure changes
# nothing.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: pin-nixie.sh <version> <release notes file>" >&2
  exit 2
fi
version="$1"
notes="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "not a release version: '$version'" >&2
  exit 2
fi
config=infra/Pulumi.prod.yaml
if [ ! -f "$config" ]; then
  echo "$config is missing: run this from the root of a zgeoff/cloud checkout" >&2
  exit 1
fi

# the list under `## Images`, up to the next heading
images="$(awk '/^## / { section = $0; next } section == "## Images"' "$notes")"

# read_digest <image>: prints the image's digest from the notes, or fails unless exactly one
# list item names it
read_digest() {
  local lines count
  lines="$(grep -E "^- \`ghcr\.io/zgeoff/$1@sha256:[0-9a-f]{64}\`\$" <<< "$images" || true)"
  count="$(grep -c . <<< "$lines" || true)"
  if [ "$count" != 1 ]; then
    echo "the release notes list $count ghcr.io/zgeoff/$1 digests under ## Images, want 1" >&2
    exit 1
  fi
  sed -E 's/^.*@(sha256:[0-9a-f]{64})`$/\1/' <<< "$lines"
}

# read_pin <image>: prints the image's "<version> <digest>" pin from the config, or fails unless
# exactly one line pins it
read_pin() {
  local lines count
  lines="$(grep -E "^ +[A-Za-z]+: ghcr\.io/zgeoff/$1:[^@]+@sha256:[0-9a-f]{64}\$" "$config" || true)"
  count="$(grep -c . <<< "$lines" || true)"
  if [ "$count" != 1 ]; then
    echo "$config has $count ghcr.io/zgeoff/$1 pins, want 1" >&2
    exit 1
  fi
  sed -E "s/^.*:([^:@]+)@(sha256:[0-9a-f]{64})\$/\1 \2/" <<< "$lines"
}

# needs_pin <image> <digest> <pin>: exits 0 when the config needs <version> for the image, and 1
# when its pin, read by read_pin, already holds <version> or a newer release; fails on <version>
# with another digest. A caller runs it as a condition, where errexit is off, so it reads nothing.
needs_pin() {
  local pinned_version="${3% *}" pinned_digest="${3#* }"
  if [ "$pinned_version" = "$version" ]; then
    if [ "$pinned_digest" != "$2" ]; then
      echo "$1 $version is pinned with $pinned_digest, but the release notes list $2" >&2
      exit 1
    fi
    echo "$1 $version is already pinned"
    return 1
  fi
  if [ "$(printf '%s\n' "$pinned_version" "$version" | sort -V | tail -1)" = "$pinned_version" ]; then
    echo "$1 $pinned_version is pinned, which is newer than $version"
    return 1
  fi
}

script=""
pinned=()
for image in nixie nixie-web; do
  digest="$(read_digest "$image")"
  pin="$(read_pin "$image")"
  if needs_pin "$image" "$digest" "$pin"; then
    script+="s|^( +[A-Za-z]+: ghcr\\.io/zgeoff/$image:)[^@]+@sha256:[0-9a-f]{64}\$|\\1$version@$digest|;"
    pinned+=("$image $version: $digest")
  fi
done
if [ -z "$script" ]; then
  exit 0
fi

# write beside the config, then rename over it, so a failed write leaves the pins as they were
sed -E "$script" "$config" > "$config.new"
chmod --reference="$config" "$config.new"
mv "$config.new" "$config"
printf 'pinned %s\n' "${pinned[@]}"
