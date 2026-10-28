#!/usr/bin/env bash
# Removes every Actions cache of the NixOS checks' store on main but <kept>, the one the run just
# saved, so main holds one such cache at a time and a run restores the newest. A gh failure fails
# the script with gh's error; a cache left behind then waits for GitHub's eviction of a cache
# unused for 7 days.
#
#   bash scripts/remove-stale-nixos-checks-caches.sh <kept>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: remove-stale-nixos-checks-caches.sh <kept cache key>" >&2
  exit 2
fi

caches="$(mktemp)"
trap 'rm -f "$caches"' EXIT
gh cache list --key nixos-checks-store-main- --ref refs/heads/main --limit 100 --json id,key \
  --jq '.[] | "\(.id) \(.key)"' > "$caches"

while read -r id key; do
  if [ "$key" != "$1" ]; then
    gh cache delete "$id"
  fi
done < "$caches"
