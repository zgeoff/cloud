#!/usr/bin/env bash
# Removes every Actions cache of the NixOS checks' store on main that an earlier run than <kept>,
# the one the run just saved, saved, so main holds the newest such cache and a run restores it. A
# failed list fails the script with gh's error. A failed delete names the cache on stderr and goes
# on; a cache left behind waits for GitHub's eviction of a cache unused for 7 days.
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

kept_run="${1##*-}"
while read -r id key; do
  run="${key##*-}"
  # runs on two commits of main overlap, so a newer run's cache stays, and a cache the other run
  # already removed fails its delete
  if [[ "$run" =~ ^[0-9]+$ ]] && [[ "$kept_run" =~ ^[0-9]+$ ]] && [ "$run" -lt "$kept_run" ]; then
    gh cache delete "$id" || echo "remove-stale-nixos-checks-caches: left $key" >&2
  fi
done < "$caches"
