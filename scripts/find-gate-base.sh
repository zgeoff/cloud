#!/usr/bin/env bash
# A push to main cancels main's earlier CI run, so the commit before a push may never have passed
# its gated checks. Only a commit that a green main run checked is a safe base for the path gates.
#
#   bash scripts/find-gate-base.sh <commit>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ] || [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "usage: GITHUB_OUTPUT=<file> find-gate-base.sh <commit>" >&2
  exit 2
fi
commit="$(git rev-parse --verify --quiet "$1^{commit}")" || {
  echo "find-gate-base: $1 is not a commit" >&2
  exit 1
}

heads="$(mktemp)"
trap 'rm -f "$heads"' EXIT
# the filter repeats the query's conditions, so a run outside them never counts
gh api -X GET "repos/{owner}/{repo}/actions/workflows/ci.yml/runs" \
  -f event=push -f branch=main -f status=success -f per_page=100 \
  --jq '.workflow_runs[] | select(.event == "push" and .head_branch == "main" and .conclusion == "success") | .head_sha' \
  > "$heads"

base=0000000000000000000000000000000000000000
while read -r head; do
  # a commit this checkout lacks, such as one a force push dropped, is no ancestor
  if [ "$head" != "$commit" ] && git merge-base --is-ancestor "$head" "$commit" 2> /dev/null; then
    base="$head"
    break
  fi
done < "$heads"
echo "base=$base" | tee -a "$GITHUB_OUTPUT"
