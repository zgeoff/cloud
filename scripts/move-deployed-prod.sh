#!/usr/bin/env bash
# Moves the deployed/prod tag of GITHUB_REPOSITORY to <revision> through GitHub's refs API, with
# force=false, so GitHub refuses a move that is not forward along the tag's history; then it
# prints "deployed/prod moved to <revision>." and appends the same line to
# GITHUB_STEP_SUMMARY. gh reads its token from GH_TOKEN. A refused or failed move fails the run
# with gh's exit status and writes no summary line. A missing or extra argument is a usage error
# (exit 2).
#
#   GITHUB_REPOSITORY=<owner/repo> GITHUB_STEP_SUMMARY=<file> bash scripts/move-deployed-prod.sh <revision>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: move-deployed-prod.sh <revision>" >&2
  exit 2
fi
revision="$1"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_STEP_SUMMARY:?}"

gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/deployed/prod" \
  -f sha="$revision" -F force=false > /dev/null
echo "deployed/prod moved to $revision." | tee -a "$GITHUB_STEP_SUMMARY"
