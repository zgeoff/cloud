#!/usr/bin/env bash
# CI's path-gate decision. A pull request compares its base with the merge commit under test. A
# push to main cancels main's earlier run, so a push compares with the last commit that a green
# main run checked (find-gate-base.sh), never with the commit before it.
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
exec bun "$here/run-decide-gates.ts" --github "$base" "$HEAD" "$@"
