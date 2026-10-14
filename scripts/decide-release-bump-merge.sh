#!/usr/bin/env bash
# Reads the event that started the release bump merge workflow and runs the merge decision
# (merge-release-bump-with-summary.sh) for the branch it names. The workflow runs it from the
# checkout's root, with the merge-release-bump.sh environment (GH_TOKEN, MERGE_TOKEN, APP_LOGIN):
#
#   bash scripts/decide-release-bump-merge.sh
#
# Two events start a decision:
#
# - workflow_run: a check workflow finished on a pull request from GITHUB_REPOSITORY, so the last
#   check to finish merges it. The branch is the run's head branch.
# - pull_request_target, labeled `auto-merge`, on a pull request from GITHUB_REPOSITORY. A run of
#   open-release-bump-pr.sh that pushes and then fails leaves the pull request without the label;
#   its checks can all finish before the next run puts the label back with no push, so no check
#   finishes after the repair. The label event is then the only thing that starts a decision.
#
# Any other event, or one from another repository, prints why and exits 0 with no decision.
# merge-release-bump.sh skips a branch that is not a release check branch.
set -euo pipefail

: "${GITHUB_EVENT_NAME:?}" "${GITHUB_EVENT_PATH:?}" "${GITHUB_REPOSITORY:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$GITHUB_EVENT_NAME" in
  workflow_run)
    branch="$(jq -r --arg repo "$GITHUB_REPOSITORY" '.workflow_run |
      select(.event == "pull_request" and .head_repository.full_name == $repo) |
      .head_branch' "$GITHUB_EVENT_PATH")"
    ;;
  pull_request_target)
    branch="$(jq -r --arg repo "$GITHUB_REPOSITORY" 'select(.action == "labeled" and
      .label.name == "auto-merge" and .pull_request.head.repo.full_name == $repo) |
      .pull_request.head.ref' "$GITHUB_EVENT_PATH")"
    ;;
  *)
    branch=""
    ;;
esac
if [ -z "$branch" ]; then
  echo "this $GITHUB_EVENT_NAME event starts no merge decision"
  exit 0
fi

exec bash "$here/merge-release-bump-with-summary.sh" "$branch"
