#!/usr/bin/env bash
# Posts the scheduled drift check's alert to Discord: "The scheduled drift check found drift in
# prod: <run>" when the check ended with drift (OUTCOME drift), else "The scheduled drift check
# failed: <run>", which covers a refresh that failed and a step before it that failed. The post is
# the JSON body {"content": …}, sent with curl -f, so a webhook that refuses it fails the run with
# curl's exit status.
#
# It reads OUTCOME (the check's outcome, empty when the run never reached the check), RUN_REF
# (where to read the run's log) and ALERT_WEBHOOK_URL, the webhook, which
# scripts/run-host-drift-check.sh loads from the host's credentials file. It never prints the
# webhook. An empty RUN_REF or ALERT_WEBHOOK_URL fails (exit 1) before curl runs. An argument is a
# usage error (exit 2).
#
#   OUTCOME=<outcome> RUN_REF=<text> ALERT_WEBHOOK_URL=<url> bash scripts/alert-scheduled-drift.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: alert-scheduled-drift.sh" >&2
  exit 2
fi
for name in RUN_REF ALERT_WEBHOOK_URL; do
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
jq -n --arg content "The scheduled drift check $what: $RUN_REF" '{content: $content}' |
  curl -fsS -H 'Content-Type: application/json' --data @- "$ALERT_WEBHOOK_URL" > /dev/null
