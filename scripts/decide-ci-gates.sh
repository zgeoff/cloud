#!/usr/bin/env bash
# CI's path-gate decision. A pull request compares its base with the merge commit under test. A
# push to main cancels main's earlier run, so a push compares with the last commit that a green
# main run checked (find-gate-base.sh), never with the commit before it.
#
# A push skips every check but the secret scan, which reads the push's history rather than its
# tree, when a green pull request run of this repository already checked the
# push's tree on a base with the same tree as that commit: the run's checks job uploads an artifact
# named ci-pass-<tree>-<base tree> (write-ci-pass-name.sh), and the same gates on the same two trees
# decide the same checks. Then it writes each gate as false and reused=true, and names the run on
# stdout and in GITHUB_STEP_SUMMARY. A gh failure fails the script with gh's error.
#
#   EVENT=<event> HEAD=<commit> [PR_BASE=<commit>] bash scripts/decide-ci-gates.sh <gate>...
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${EVENT:-}" ] || [ -z "${HEAD:-}" ] || [ "$#" -eq 0 ] ||
  { [ "$EVENT" = pull_request ] && [ -z "${PR_BASE:-}" ]; }; then
  echo "usage: EVENT=<event> HEAD=<commit> [PR_BASE=<commit>] decide-ci-gates.sh <gate>..." >&2
  exit 2
fi

if [ "$EVENT" = pull_request ]; then
  base="$PR_BASE"
else
  base="$(bash "$here/find-gate-base.sh" "$HEAD")"
fi

if [ "$EVENT" = push ] && [ "$base" != 0000000000000000000000000000000000000000 ]; then
  : "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}" "${GITHUB_SERVER_URL:?}" "${GITHUB_REPOSITORY:?}"
  name="ci-pass-$(git rev-parse "$HEAD^{tree}")-$(git rev-parse "$base^{tree}")"
  run="$(gh api -X GET "repos/{owner}/{repo}/actions/artifacts" -f name="$name" -f per_page=100 \
    --jq '[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty')"
  if [ -n "$run" ]; then
    lines="$(printf '%s=false\n' "$@")"
    printf '%s\nreused=true\n' "$lines" | tee -a "$GITHUB_OUTPUT"
    echo "Pull request run $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$run passed this tree on the same base tree, so the checks did not run again." | tee -a "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
fi
exec bun "$here/run-decide-gates.ts" --github "$base" "$HEAD" "$@"
