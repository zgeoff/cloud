#!/usr/bin/env bash
# Finds the green NixOS checks run that covers <commit>, and prints its URL; it prints nothing
# when no run covers it. A run covers the commit when it is a scheduled or dispatched run of
# .github/workflows/nixos-checks.yml on main that succeeded, its commit is <commit> or an ancestor
# of it, and scripts/run-decide-gates.ts finds that no commit between the two changes an input of the
# checks, which the nixos gate of .github/gates.yml lists.
# Runs on other branches and pull request runs never count: they checked a commit main may not
# hold. The nightly run reads it to skip a commit that is already covered, and
# scripts/switch-geoffcloud.sh to refuse a commit that is not.
#
# It reads the 100 newest green runs, newest first, with gh, which resolves {owner}/{repo} from
# the checkout's remote. A gh failure fails the script with gh's exit and error, so a caller
# never reads an outage as "not covered" or as "covered". A run whose commit the checkout does not
# have is skipped.
#
#   bash scripts/find-nixos-check-run.sh <commit>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: find-nixos-check-run.sh <commit>" >&2
  exit 2
fi
commit="$(git rev-parse --verify --quiet "$1^{commit}")" || {
  echo "find-nixos-check-run: $1 is not a commit" >&2
  exit 1
}

runs="$(mktemp)"
trap 'rm -f "$runs"' EXIT
gh api -X GET "repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs" \
  -f branch=main -f status=success -f per_page=100 \
  --jq '.workflow_runs[] | select(.event == "schedule" or .event == "workflow_dispatch") | "\(.head_sha) \(.html_url)"' \
  > "$runs"

while read -r sha url; do
  git cat-file -e "$sha^{commit}" 2> /dev/null || continue
  # a run on a commit off <commit>'s history never covers it: run-decide-gates.ts needs every gate for
  # a base that is not an ancestor of the head
  needed="$(bun "$(dirname "${BASH_SOURCE[0]}")/run-decide-gates.ts" "$sha" "$commit" nixos)"
  if [ "$needed" = nixos=false ]; then
    echo "$url"
    exit 0
  fi
done < "$runs"
