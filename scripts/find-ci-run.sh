#!/usr/bin/env bash
# Finds the green CI run of a push to main on exactly <commit>, and prints its URL; it prints
# nothing when no such run exists, as while CI still runs or after it failed. A run on another
# branch, a pull request's run or a run on any other commit never counts. The prod apply job's
# manual dispatch reads it, because a dispatch skips the workflow_run trigger that waits for CI.
#
# It asks gh, which resolves {owner}/{repo} from the checkout's remote, for the workflow's runs
# filtered by commit, event, branch and status. A gh failure fails the script with gh's exit and
# error, so a caller never reads an outage as "no green run" or as "green". A <commit> git cannot
# resolve fails with exit 1, and a missing argument is a usage error (exit 2).
#
#   bash scripts/find-ci-run.sh <commit>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: find-ci-run.sh <commit>" >&2
  exit 2
fi
commit="$(git rev-parse --verify --quiet "$1^{commit}")" || {
  echo "find-ci-run: $1 is not a commit" >&2
  exit 1
}

runs="$(mktemp)"
trap 'rm -f "$runs"' EXIT
# the filter repeats the query's conditions, so a run outside them never counts
gh api -X GET "repos/{owner}/{repo}/actions/workflows/ci.yml/runs" \
  -f head_sha="$commit" -f event=push -f branch=main -f status=success -f per_page=100 \
  --jq ".workflow_runs[] | select(.head_sha == \"$commit\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url" \
  > "$runs"
head -n 1 "$runs"
