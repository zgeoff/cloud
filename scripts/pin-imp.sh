#!/usr/bin/env bash
# Pin an imp release: the imp input in nixos/flake.nix and nixos/flake.lock together with the
# imp-host image in nixos/hosts/geoffcloud/configuration.nix, because the module and the image move
# together, and the imp-base image that images/agent/Dockerfile builds on. Run it from the root of
# a zgeoff/cloud checkout, with docker. The release check runs it with the release tag's commit and
# the two images' digests (scripts/bump-release.sh):
#
#   bash scripts/pin-imp.sh <version> <commit> <imp-host digest> <imp-base digest>
#
# NIX_GITHUB_TOKEN, when set, is a GitHub token that the lock sends to api.github.com, so a shared
# runner IP's anonymous rate limit cannot fail it; the release check passes its job's token.
#
# The flake input takes the commit's first 8 hex digits, as it does by hand, and `nix flake lock`
# then locks it, in the Nix image that scripts/nix-image.sh pins; the lock must name the
# commit. The rules follow pin-agent-atc.sh's for each image on its own: an image that already
# holds <version> and its digest, or a newer version, stays as it is, and one that holds <version>
# with another digest fails, because a release's images never change. It checks both images
# before it writes, so a failed image check changes nothing. A failed lock leaves flake.nix
# rewritten, and a lock of another commit leaves flake.lock rewritten too; open-release-bump-pr.sh
# then pushes nothing, and the release check resets the tree before its next bump.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: pin-imp.sh <version> <commit> <imp-host digest> <imp-base digest>" >&2
  exit 2
fi
version="$1"
commit="$2"
host_digest="$3"
base_digest="$4"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "not a release version: '$version'" >&2
  exit 2
fi
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "not a commit: '$commit'" >&2
  exit 2
fi
for digest in "$host_digest" "$base_digest"; do
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "not an image digest: '$digest'" >&2
    exit 2
  fi
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flake=nixos/flake.nix
lock=nixos/flake.lock
config=nixos/hosts/geoffcloud/configuration.nix
dockerfile=images/agent/Dockerfile
for file in "$flake" "$lock" "$config" "$dockerfile"; do
  if [ ! -f "$file" ]; then
    echo "$file is missing: run this from the root of a zgeoff/cloud checkout" >&2
    exit 1
  fi
done

# read_pin <file> <pattern>: prints the "<version> <digest>" that the one line matching the
# extended regex captures, or fails unless exactly one line matches
read_pin() {
  local lines count
  lines="$(grep -E "$2" "$1" || true)"
  count="$(grep -c . <<< "$lines" || true)"
  if [ "$count" != 1 ]; then
    echo "$1 has $count lines that match '$2', want 1" >&2
    exit 1
  fi
  sed -E "s|$2|\\1 \\2|" <<< "$lines"
}

# needs_pin <image> <digest> <pin>: exits 0 when the image needs <version>, and 1 when its pin,
# read by read_pin, already holds <version> or a newer release; fails on <version> with another
# digest. A caller runs it as a condition, where errexit is off, so it reads nothing.
needs_pin() {
  local pinned_version="${3% *}" pinned_digest="${3#* }"
  if [ "$pinned_version" = "$version" ]; then
    if [ "$pinned_digest" != "$2" ]; then
      echo "$1 $version is pinned with $pinned_digest, but the registry lists $2" >&2
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

# write <file> <sed script>: rewrites the file beside itself, then renames it over the original
write() {
  sed -E "$2" "$1" > "$1.new"
  chmod --reference="$1" "$1.new"
  mv "$1.new" "$1"
}

host_pattern='^    image = "ghcr\.io/zgeoff/imp-host:([^@"]+)@(sha256:[0-9a-f]{64})";$'
base_pattern='^FROM ghcr\.io/zgeoff/imp-base:([^@ ]+)@(sha256:[0-9a-f]{64})$'
input_pattern='^      url = "github:zgeoff/imp/([0-9a-f]+)";$'
host_pin="$(read_pin "$config" "$host_pattern")"
base_pin="$(read_pin "$dockerfile" "$base_pattern")"
count="$(grep -cE "$input_pattern" "$flake" || true)"
if [ "$count" != 1 ]; then
  echo "$flake has $count lines that match '$input_pattern', want 1" >&2
  exit 1
fi

pin_host=false
pin_base=false
if needs_pin imp-host "$host_digest" "$host_pin"; then pin_host=true; fi
if needs_pin imp-base "$base_digest" "$base_pin"; then pin_base=true; fi

if [ "$pin_host" = true ]; then
  write "$flake" "s|^(      url = \"github:zgeoff/imp/)[0-9a-f]+(\";)\$|\\1${commit:0:8}\\2|"
  # shellcheck source-path=SCRIPTDIR source=nix-image.sh
  source "$here/nix-image.sh"
  # the lock resolves the short commit through api.github.com, whose anonymous quota a shared
  # runner IP can spend; with NIX_GITHUB_TOKEN, nix sends it as a github.com access token. docker
  # takes NIX_CONFIG by name, so the token stays out of every argv and log line.
  if [ -n "${NIX_GITHUB_TOKEN:-}" ]; then
    export NIX_CONFIG="access-tokens = github.com=$NIX_GITHUB_TOKEN"
  fi
  docker run --rm -v "$PWD/nixos:/src" -w /src -e NIX_CONFIG "$NIX_IMAGE" sh -c \
    "nix --extra-experimental-features 'nix-command flakes' flake lock && chown $(id -u):$(id -g) flake.lock"
  locked="$(jq -r '.nodes.imp.locked.rev' "$lock")"
  if [ "$locked" != "$commit" ]; then
    echo "$lock locks imp at $locked, want $commit" >&2
    exit 1
  fi
  write "$config" "s|^(    image = \"ghcr\\.io/zgeoff/imp-host:)[^@\"]+@sha256:[0-9a-f]{64}(\";)\$|\\1$version@$host_digest\\2|"
  echo "pinned imp $version in $flake and $lock: $commit"
  echo "pinned imp-host $version: $host_digest"
fi
if [ "$pin_base" = true ]; then
  write "$dockerfile" "s|^(FROM ghcr\\.io/zgeoff/imp-base:)[^@ ]+@sha256:[0-9a-f]{64}\$|\\1$version@$base_digest|"
  echo "pinned imp-base $version: $base_digest"
fi
