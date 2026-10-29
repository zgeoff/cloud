#!/usr/bin/env bash
# Writes the NixOS checks' local binary cache to <dir> after a build, for the next run's build to
# substitute from (run-nixos-checks.sh, NIXOS_CHECKS_CACHE). It holds each output in the build
# closure of the derivations that <derivations> lists which the store volume holds and
# cache.nixos.org did not sign: the paths this runner built, or took from the cache it restored.
# The next run fetches the signed ones from cache.nixos.org itself. It lists those paths in
# <dir>/paths, moves <dir> to <restored> in place of the cache restored there, and writes
# `saved=true` to GITHUB_OUTPUT: actions/cache matches a saved cache only to a restore of the same
# path, so the next run restores it at <restored>. It writes `saved=false` when the paths are
# the ones <restored>/paths lists, so an unchanged cache is not saved again, or when <dir> outgrows
# NIXOS_CHECKS_CACHE_MAX_MB megabytes (default 3072), the cap that keeps one cache within the
# repository's Actions cache storage; it says why on stdout.
#
#   bash scripts/write-nixos-checks-cache.sh <derivations> <restored> <dir>
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

: "${GITHUB_OUTPUT:?}"
if [ "$#" -ne 3 ] || [ ! -s "$1" ] || [ -e "$3" ]; then
  echo "usage: write-nixos-checks-cache.sh <derivations> <restored> <dir>, a folder that does not exist yet" >&2
  exit 2
fi
derivations="$1"
restored="$2"
dir="$3"
volume="${NIX_STORE_VOLUME:-cloud-nixos-checks-store}"
max_mb="${NIXOS_CHECKS_CACHE_MAX_MB:-3072}"
nix_args=(--extra-experimental-features nix-command)

outputs="$(mktemp)"
info="$(mktemp)"
stand_ins="$(mktemp)"
trap 'rm -f "$outputs" "$info" "$stand_ins"' EXIT

mapfile -t drvs < "$derivations"
docker run --rm -v "$volume":/nix "$NIX_IMAGE" nix-store -qR --include-outputs "${drvs[@]}" |
  { grep -v '\.drv$' || true; } > "$outputs"
docker run --rm -i -v "$volume":/nix "$NIX_IMAGE" nix "${nix_args[@]}" path-info --json --stdin \
  < "$outputs" > "$info"

mkdir -p "$dir"
# nix 2.35 prints an object keyed by path; earlier releases printed an array of objects
jq -r 'if type == "array" then .[] | {key: .path, value: .} else to_entries[] end
  | select((.value.signatures // []) | any(startswith("cache.nixos.org-1:")) | not) | .key' \
  "$info" | LC_ALL=C sort > "$dir/paths"

if [ -f "$restored/paths" ] && cmp -s "$restored/paths" "$dir/paths"; then
  echo "saved=false" >> "$GITHUB_OUTPUT"
  echo "The cache holds the paths this build needed, so it was not saved again."
  exit 0
fi
# A binary cache refuses a path whose references it lacks, so each signed reference gets a narinfo
# for the copy and loses it after: the next run's nix substitutes those from cache.nixos.org.
jq -r --rawfile copied "$dir/paths" '
  (if type == "array" then map({key: .path, value: .}) else to_entries end | from_entries) as $all
  | ($copied | split("\n") | map(select(. != "") | {key: ., value: true}) | from_entries) as $set
  | [$set | keys[] | $all[.].references // [] | .[] | select($set[.] | not)] | unique[]
  | select($all[.]) | . as $path | $all[$path]
  | ($path | ltrimstr("/nix/store/") | .[0:32]) + "\t"
    + ("StorePath: \($path)\nURL: nar/none\nCompression: none\nNarHash: \(.narHash)\nNarSize: \(.narSize)\nReferences: \(.references // [] | map(ltrimstr("/nix/store/")) | join(" "))\n" | @base64)' \
  "$info" > "$stand_ins"
while IFS=$'\t' read -r hash text; do
  base64 -d <<< "$text" > "$dir/$hash.narinfo"
done < "$stand_ins"
docker run --rm -i -v "$volume":/nix -v "$(realpath "$dir")":/cache "$NIX_IMAGE" \
  nix "${nix_args[@]}" copy --no-recursive --stdin --to 'file:///cache?compression=zstd' < "$dir/paths"
cut -f1 "$stand_ins" | while read -r hash; do rm "$dir/$hash.narinfo"; done

size_mb="$(du -sm "$dir" | cut -f1)"
if [ "$size_mb" -gt "$max_mb" ]; then
  echo "saved=false" >> "$GITHUB_OUTPUT"
  echo "The cache came to $size_mb MB, over its cap of $max_mb MB, so it was not saved."
  exit 0
fi
count="$(wc -l < "$dir/paths")"
rm -rf "$restored"
mv "$dir" "$restored"
echo "saved=true" >> "$GITHUB_OUTPUT"
echo "The cache holds $count paths in $size_mb MB."
