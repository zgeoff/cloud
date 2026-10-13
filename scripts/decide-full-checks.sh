#!/usr/bin/env bash
# Decide, for the CI job, whether a change needs the full checks: needs-full-checks.sh decides from
# the change between <base> and <head>, and this writes its answer to the step's outputs as
# full=true or full=false. On false it also says which checks did not run, on stdout and in
# GITHUB_STEP_SUMMARY, so every run reports a result. Any answer other than true or false, or a
# failed decision, fails the step, so the job never skips the checks on an error. It runs from the
# repo root, as the workflow step does.
#
#   GITHUB_OUTPUT=… GITHUB_STEP_SUMMARY=… bash scripts/decide-full-checks.sh <base> <head>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GITHUB_OUTPUT:?set GITHUB_OUTPUT to the file that takes the step outputs}"
: "${GITHUB_STEP_SUMMARY:?set GITHUB_STEP_SUMMARY to the file that takes the step summary}"

needed="$(bash "$here/needs-full-checks.sh" "$@")"
case "$needed" in
  true | false) echo "full=$needed" >> "$GITHUB_OUTPUT" ;;
  *)
    echo "unexpected decision: $needed" >&2
    exit 1
    ;;
esac
if [ "$needed" = false ]; then
  echo "Only Markdown files changed, so the Nix-image linters and the shell suites did not run." | tee -a "$GITHUB_STEP_SUMMARY"
fi
