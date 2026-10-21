#!/usr/bin/env bash
# The Deploy prod check job's verdict on nixie's API check, which the apply job runs with
# continue-on-error once the apply is done, so a failed check fails this job and not the apply. It
# reads NIXIE_CHECK, the outcome of the apply job's step `Check nixie's API`: success passes
# (exit 0), and any other outcome, an empty one included, fails (exit 1) with an error annotation
# that points at the step's log.
#
#   NIXIE_CHECK=<outcome> bash scripts/require-nixie-check.sh
set -euo pipefail

if [ "${NIXIE_CHECK:-}" = success ]; then
  echo "nixie's API check passed"
  exit 0
fi
echo "::error::nixie's API check ended '${NIXIE_CHECK:-}'; the apply job's step Check nixie's API logs why"
exit 1
