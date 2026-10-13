#!/usr/bin/env bash
# Print the labels of a release bump pull request, one per line: its update type, its review
# flags, and whether it may merge on its own.
#
#   bash scripts/label-release-bump.sh <version> <pinned version>... [-- <flag>...]
#
# - `update:major`, `update:minor` or `update:patch`: the largest step from a pinned version older
#   than <version> to <version>. A pin at <version> or newer moves nothing, so it does not count.
# - each <flag>, such as `migrations` or `sandbox-images-changed` from find-nixie-release-flags.sh.
# - `needs-review` for a major update, for a minor update to a 0.x release (where a minor release
#   is the breaking one), and for any flag; `auto-merge` otherwise. One rule serves atc, imp and
#   nixie: from 1.0 on, patch and minor updates merge on their own.
#
# It fails when no pinned version is older than <version>, since such a bump changes nothing.
set -euo pipefail

usage="usage: label-release-bump.sh <version> <pinned version>... [-- <flag>...]"
version_pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
if [ "$#" -lt 2 ] || [ "$2" = -- ]; then
  echo "$usage" >&2
  exit 2
fi
version="$1"
shift
pinned=()
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  pinned+=("$1")
  shift
done
if [ "$#" -gt 0 ]; then shift; fi
flags=("$@")

for each in "$version" "${pinned[@]}"; do
  if [[ ! "$each" =~ $version_pattern ]]; then
    echo "not a release version: '$each'" >&2
    exit 2
  fi
done
[[ "$version" =~ $version_pattern ]]
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"

# rank: 0 for no older pin, 1 for patch, 2 for minor, 3 for major
rank=0
for each in "${pinned[@]}"; do
  if [ "$(printf '%s\n' "$each" "$version" | sort -V | tail -1)" = "$each" ]; then
    continue
  fi
  [[ "$each" =~ $version_pattern ]]
  if [ "${BASH_REMATCH[1]}" != "$major" ]; then
    step=3
  elif [ "${BASH_REMATCH[2]}" != "$minor" ]; then
    step=2
  else
    step=1
  fi
  if [ "$step" -gt "$rank" ]; then rank="$step"; fi
done
case "$rank" in
  0)
    echo "no pinned version is older than $version" >&2
    exit 1
    ;;
  1) update=patch ;;
  2) update=minor ;;
  3) update=major ;;
esac

echo "update:$update"
if [ "${#flags[@]}" -gt 0 ]; then
  printf '%s\n' "${flags[@]}"
fi
if [ "$update" = major ] || { [ "$update" = minor ] && [ "$major" = 0 ]; } || [ "${#flags[@]}" -gt 0 ]; then
  echo needs-review
else
  echo auto-merge
fi
