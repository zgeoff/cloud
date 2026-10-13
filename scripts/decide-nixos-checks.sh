#!/usr/bin/env bash
# Decides whether the NixOS checks workflow builds the checks for GITHUB_SHA, and writes the
# answer as `needed=true` or `needed=false` to GITHUB_OUTPUT. A dispatch and an app's pull request
# (any GITHUB_EVENT_NAME but schedule) always build. A nightly run skips a commit that a green run
# already covers (find-nixos-check-run.sh), and says so on stdout and in GITHUB_STEP_SUMMARY. A
# failure of that search, such as a gh outage, fails the script with its error and writes nothing,
# so the job fails rather than skipping the checks. The workflow's decision step runs it from the
# checkout's root:
#
#   bash scripts/decide-nixos-checks.sh
set -euo pipefail

: "${GITHUB_EVENT_NAME:?}" "${GITHUB_SHA:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$GITHUB_EVENT_NAME" != schedule ]; then
  echo "needed=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
covered="$(bash "$here/find-nixos-check-run.sh" "$GITHUB_SHA")"
if [ -n "$covered" ]; then
  echo "needed=false" >> "$GITHUB_OUTPUT"
  echo "No input of the NixOS checks changed since $covered, so the checks did not run." | tee -a "$GITHUB_STEP_SUMMARY"
else
  echo "needed=true" >> "$GITHUB_OUTPUT"
fi
