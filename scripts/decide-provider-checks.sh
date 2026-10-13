#!/usr/bin/env bash
# Decide, for the CI job, whether a change needs the provider's Go checks and the SDK check:
# needs-provider-check.sh decides from the change between <base> and <head>, and this writes its
# answer to the step's outputs as provider=true or provider=false. On false it also says the Go
# checks did not run, on stdout and in GITHUB_STEP_SUMMARY, so every run reports a result. Any
# answer other than true or false, or a failed decision, fails the step, so the job never skips the
# checks on an error. It runs from the repo root, as the workflow step does.
#
#   GITHUB_OUTPUT=… GITHUB_STEP_SUMMARY=… bash scripts/decide-provider-checks.sh <base> <head>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GITHUB_OUTPUT:?set GITHUB_OUTPUT to the file that takes the step outputs}"
: "${GITHUB_STEP_SUMMARY:?set GITHUB_STEP_SUMMARY to the file that takes the step summary}"

needed="$(bash "$here/needs-provider-check.sh" "$@")"
case "$needed" in
  true | false) echo "provider=$needed" >> "$GITHUB_OUTPUT" ;;
  *)
    echo "unexpected decision: $needed" >&2
    exit 1
    ;;
esac
if [ "$needed" = false ]; then
  echo "No input of the provider checks changed, so the Go checks did not run." | tee -a "$GITHUB_STEP_SUMMARY"
fi
