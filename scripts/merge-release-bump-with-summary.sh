#!/usr/bin/env bash
# Runs merge-release-bump.sh with its arguments and copies what it prints on stdout, such as why a
# pull request stays open, to GITHUB_STEP_SUMMARY as well. It exits with merge-release-bump.sh's
# status, so a failed merge decision fails the step. The release bump merge workflow runs it with
# the merge-release-bump.sh environment (GH_TOKEN, MERGE_TOKEN, APP_LOGIN):
#
#   bash scripts/merge-release-bump-with-summary.sh <branch>
set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$here/merge-release-bump.sh" "$@" | tee -a "$GITHUB_STEP_SUMMARY"
