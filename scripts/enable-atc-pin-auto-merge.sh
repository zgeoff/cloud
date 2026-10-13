#!/usr/bin/env bash
# Turns on auto-merge (squash) for the atc pin pull request <pr> in GITHUB_REPOSITORY, only while
# its head is still <head sha>, so a late run never turns auto-merge on for a head it did not check.
# The ruleset's required checks still gate the merge. The agent image workflow's auto-merge job runs
# it once the image check passed and check-atc-pin-diff.sh found only the two atc pins changed,
# with gh signed in to a token that may write pull requests:
#
#   bash scripts/enable-atc-pin-auto-merge.sh <pr> <head sha>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: enable-atc-pin-auto-merge.sh <pr> <head sha>" >&2
  exit 2
fi
: "${GITHUB_REPOSITORY:?}"

gh pr merge "$1" --repo "$GITHUB_REPOSITORY" --auto --squash --match-head-commit "$2"
