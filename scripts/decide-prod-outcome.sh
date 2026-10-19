#!/usr/bin/env bash
# The prod apply job's outcome once the guard has read the plan: it writes outcome=apply or
# outcome=held to $GITHUB_OUTPUT, for the job's later steps and the alert job. A plan the guard
# passes (VERDICT apply) applies, and so does a held plan on a manual dispatch (EVENT
# workflow_dispatch), because the person who dispatches it has read the held plan. A held plan on
# any other event ends the run as held, not failed: the script prints a notice that names the
# revision to dispatch, adds the same line to $GITHUB_STEP_SUMMARY and exits 0, so the job
# succeeds and leaves the deploy-prod concurrency group to the next push's run. Any other verdict,
# an empty one included, fails the run (exit 1), so the job never applies a plan the guard did not
# judge. A missing variable is a usage error (exit 2).
#
#   VERDICT=<apply|hold> EVENT=<event> REVISION=<commit> bash scripts/decide-prod-outcome.sh
#
# It also reads GITHUB_OUTPUT and GITHUB_STEP_SUMMARY.
set -euo pipefail

for name in EVENT REVISION GITHUB_OUTPUT GITHUB_STEP_SUMMARY; do
  if [ -z "${!name:-}" ]; then
    echo "decide-prod-outcome: set $name" >&2
    exit 2
  fi
done

case "${VERDICT:-}" in
  apply) outcome=apply ;;
  hold)
    if [ "$EVENT" = workflow_dispatch ]; then
      outcome=apply
    else
      outcome=held
    fi
    ;;
  *)
    echo "decide-prod-outcome: the guard gave no verdict to act on: '${VERDICT:-}'" >&2
    exit 1
    ;;
esac

echo "outcome=$outcome" >> "$GITHUB_OUTPUT"
if [ "$outcome" = held ]; then
  line="The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision $REVISION."
  echo "::notice::$line"
  echo "$line" >> "$GITHUB_STEP_SUMMARY"
fi
