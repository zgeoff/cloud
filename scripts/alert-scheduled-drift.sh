#!/usr/bin/env bash
# Posts the Drift check alert to Discord: "The scheduled drift check found drift in prod: <run>"
# when the check ended with drift (OUTCOME drift), else "The scheduled drift check failed: <run>",
# which covers a refresh that failed, a step before it that failed, and a cancelled run. The post
# is the JSON body {"content": …}, sent with curl -f, so a webhook that refuses it fails the run
# with curl's exit status.
#
# It reads OUTCOME (the check job's outcome, empty when that job never reached the check), RUN_URL
# (the run's page) and ALERT_WEBHOOK_URL, the webhook, which the workflow loads from the cloud-ci
# vault and GitHub masks in the log. It never prints the webhook. An empty RUN_URL or
# ALERT_WEBHOOK_URL fails (exit 1) before curl runs. An argument is a usage error (exit 2).
#
#   OUTCOME=<outcome> RUN_URL=<url> ALERT_WEBHOOK_URL=<url> bash scripts/alert-scheduled-drift.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: alert-scheduled-drift.sh" >&2
  exit 2
fi
for name in RUN_URL ALERT_WEBHOOK_URL; do
  if [ -z "${!name:-}" ]; then
    echo "alert-scheduled-drift: $name is empty" >&2
    exit 1
  fi
done

if [ "${OUTCOME:-}" = drift ]; then
  what="found drift in prod"
else
  what="failed"
fi
jq -n --arg content "The scheduled drift check $what: $RUN_URL" '{content: $content}' |
  curl -fsS -H 'Content-Type: application/json' --data @- "$ALERT_WEBHOOK_URL" > /dev/null
