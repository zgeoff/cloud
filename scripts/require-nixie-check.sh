#!/usr/bin/env bash
# The Deploy prod check job's verdict on the checks of nixie that the apply job runs with
# continue-on-error once the apply is done, so a failed check fails this job and not the apply. It
# reads NIXIE_API_CHECK and NIXIE_DOCTOR_CHECK, the outcomes of the apply job's steps `Check
# nixie's API` and `Check nixie with its doctor`. It prints a line for each: success passes, and any
# other outcome, an empty one included, prints an error annotation that points at the step's log.
# It exits 0 when both passed, else 1.
#
#   NIXIE_API_CHECK=<outcome> NIXIE_DOCTOR_CHECK=<outcome> bash scripts/require-nixie-check.sh
set -euo pipefail

status=0

# require_outcome <what> <step> <outcome>
require_outcome() {
  if [ "$3" = success ]; then
    echo "$1 passed"
  else
    echo "::error::$1 ended '$3'; the apply job's step $2 logs why"
    status=1
  fi
}

require_outcome "nixie's API check" "Check nixie's API" "${NIXIE_API_CHECK:-}"
require_outcome "nixie's prod doctor" "Check nixie with its doctor" "${NIXIE_DOCTOR_CHECK:-}"
exit "$status"
