#!/usr/bin/env bash
# The prod apply job's preview and guard: it builds the SDK, previews the prod stack with a
# refresh into $RUNNER_TEMP/plan.json, and runs the guard (check-prod-plan.ts) on that plan and
# DRIFT, the outcome of the drift check from the deployed revision. The preview runs through
# retry-transient-pulumi.sh, which runs it again after an ACME server's 5xx or a failed plugin
# download. The guard's text goes to stdout and to $GITHUB_STEP_SUMMARY, and its verdict to
# $GITHUB_OUTPUT: verdict=apply when it passes the plan (exit 0), verdict=hold when it holds it
# (exit 3).
#
# The plan digest stays on the runner: the guard prints each held step's op and URN, never a
# resource's state. A failed SDK build fails the run with its status before the preview. A failed
# preview still runs the guard and shows its text, then fails the run (exit 1) and names the
# preview's status; any other guard status fails it too (exit 1), with no verdict. Missing
# variables are a usage error (exit 2).
#
#   RUNNER_TEMP=<dir> DRIFT=<success|failure> bash scripts/preview-and-guard-prod.sh
#
# It also reads GITHUB_OUTPUT and GITHUB_STEP_SUMMARY, and passes its environment, the deploy
# vault's OP_SERVICE_ACCOUNT_TOKEN among it, to the preview. It runs in the job's checkout.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in RUNNER_TEMP DRIFT GITHUB_OUTPUT GITHUB_STEP_SUMMARY; do
  if [ -z "${!name:-}" ]; then
    echo "preview-and-guard-prod: set $name" >&2
    exit 2
  fi
done

bun run sdk:build
preview=0
bash "$here/retry-transient-pulumi.sh" --out "$RUNNER_TEMP/plan.json" \
  bun run --silent preview -- --refresh --json || preview=$?
guard=0
bun run --silent ci:check-prod-plan "$RUNNER_TEMP/plan.json" "$DRIFT" > "$RUNNER_TEMP/guard.txt" || guard=$?
tee -a "$GITHUB_STEP_SUMMARY" < "$RUNNER_TEMP/guard.txt"
if [ "$preview" != 0 ]; then
  echo "the preview failed (exit $preview)" >&2
  exit 1
fi
case "$guard" in
  0) echo "verdict=apply" >> "$GITHUB_OUTPUT" ;;
  3) echo "verdict=hold" >> "$GITHUB_OUTPUT" ;;
  *) exit 1 ;;
esac
