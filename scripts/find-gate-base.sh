#!/usr/bin/env bash
# The base that CI's checks job on a push to main compares <commit> with, to decide its path gates:
# the newest commit before <commit> that a green CI run of a push to main checked. A push to main
# cancels main's earlier run, so the commit before the push may never have passed its gated checks;
# a green run's commit has, because that run compared with a green commit in turn. It writes
# base=<commit> to $GITHUB_OUTPUT and stdout, and base=<40 zeros> when no green run checked an
# ancestor, which runs every gated check.
#
# It asks gh, which resolves {owner}/{repo} from the checkout's remote, for the workflow's green
# push runs on main, newest first. A gh failure fails the script with gh's exit and error, so a
# caller never skips a check on an outage. A <commit> git cannot resolve fails with exit 1, and a
# missing argument or GITHUB_OUTPUT is a usage error (exit 2).
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
