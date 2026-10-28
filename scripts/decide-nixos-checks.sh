#!/usr/bin/env bash
# Decides whether the NixOS checks workflow builds the checks for the checkout's HEAD, which is a
# pull request's merge commit on a pull request's run, and writes the
# answer as `needed=true` or `needed=false` to GITHUB_OUTPUT. A dispatch with FORCE=true always
# builds. Any other run skips a commit that a green run on main already covers
# (find-nixos-check-run.sh), and says so on stdout and in GITHUB_STEP_SUMMARY; a run that is not
# skipped goes on to compare the checks' derivations (decide-nixos-checks-build.sh). A failure of
# that search, such as a gh outage, fails the script with its error and writes nothing, so the job
# fails rather than skipping the checks. The workflow's decision step runs it from the checkout's
# root:
#
#   [FORCE=true] bash scripts/decide-nixos-checks.sh
set -euo pipefail

: "${GITHUB_EVENT_NAME:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$GITHUB_EVENT_NAME" = workflow_dispatch ] && [ "${FORCE:-}" = true ]; then
  echo "needed=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
covered="$(bash "$here/find-nixos-check-run.sh" "$(git rev-parse HEAD)")"
if [ -n "$covered" ]; then
  echo "needed=false" >> "$GITHUB_OUTPUT"
  echo "No input of the NixOS checks changed since $covered, so the checks did not run." | tee -a "$GITHUB_STEP_SUMMARY"
else
  echo "needed=true" >> "$GITHUB_OUTPUT"
fi
