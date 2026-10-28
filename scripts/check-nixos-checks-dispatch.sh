#!/usr/bin/env bash
# Refuses a NixOS checks run that breaks the once-per-pull-request rule (docs/runbooks/ops.md): a
# run on a branch other than main must name its open pull request in PULL_REQUEST, dispatched on
# that pull request's head branch at its head, and CI's checks must have passed on that head, so
# the run checks the merge commit of a head that is ready to merge. A run on main names no pull
# request. A nightly run passes. A refusal exits 1 with the reason; a gh failure fails with gh's
# error.
#
#   GITHUB_EVENT_NAME=<event> GITHUB_REF_NAME=<branch> GITHUB_SHA=<commit> \
#     GITHUB_REPOSITORY=<owner/repo> [PULL_REQUEST=<number>] bash scripts/check-nixos-checks-dispatch.sh
set -euo pipefail

: "${GITHUB_EVENT_NAME:?}" "${GITHUB_REF_NAME:?}" "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}"
pr="${PULL_REQUEST:-}"

if [ "$GITHUB_EVENT_NAME" != workflow_dispatch ]; then
  exit 0
fi
if [ "$GITHUB_REF_NAME" = main ]; then
  if [ -n "$pr" ]; then
    echo "check-nixos-checks-dispatch: a run on main checks main; dispatch pull request #$pr's run on its head branch with bun run ops:nixos-checks -- --pr $pr" >&2
    exit 1
  fi
  exit 0
fi
if [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
  echo "check-nixos-checks-dispatch: a run on $GITHUB_REF_NAME checks its pull request's merge commit; dispatch it with bun run ops:nixos-checks -- --pr <number>" >&2
  exit 1
fi

pull="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr" --jq '"\(.state) \(.head.ref) \(.head.sha)"')"
read -r state ref head <<< "$pull"
if [ "$state" != open ] || [ "$ref" != "$GITHUB_REF_NAME" ] || [ "$head" != "$GITHUB_SHA" ]; then
  echo "check-nixos-checks-dispatch: pull request #$pr is $state at $ref $head, not open at $GITHUB_REF_NAME $GITHUB_SHA" >&2
  exit 1
fi
checks="$(gh api -X GET "repos/$GITHUB_REPOSITORY/commits/$head/check-runs" -f check_name=checks \
  --jq '[.check_runs[] | select(.app.slug == "github-actions")][0].conclusion // "missing"')"
if [ "$checks" != success ]; then
  echo "check-nixos-checks-dispatch: CI's checks on $head are $checks; dispatch once they pass on the head you merge" >&2
  exit 1
fi
