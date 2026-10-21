#!/usr/bin/env bash
# Posts the Deploy prod alert to Discord: "The prod apply is held for a manual dispatch: <run>"
# when the run ended held (OUTCOME held), "The prod apply passed, but nixie's API check after it
# failed: <run>" when the check job failed (CHECK_RESULT failure), else "The prod apply failed:
# <run>". The webhook URL is a secret: it reads ALERT_WEBHOOK_URL's
# op:// reference from <env file>, resolves it with `op read`, and prints only the
# ::add-mask:: line that hides it in the rest of the log. The post is the JSON body
# {"content": …}, sent with curl -f, so a webhook that refuses it fails the run with curl's
# exit status.
#
# It reads OUTCOME (the apply job's outcome, empty when that job never reached it), CHECK_RESULT
# (the check job's result, which runs only after an apply job that applied and passed) and RUN_URL
# (the run's page), and op reads its token from OP_SERVICE_ACCOUNT_TOKEN. An env file with no ALERT_WEBHOOK_URL, or an empty token, fails
# (exit 1) before op runs. A missing or extra argument is a usage error (exit 2).
#
#   OUTCOME=<outcome> CHECK_RESULT=<result> RUN_URL=<url> bash scripts/alert-prod-apply.sh <env file>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: alert-prod-apply.sh <env file>" >&2
  exit 2
fi
file="$1"
: "${RUN_URL:?}"

if [ "${OUTCOME:-}" = held ]; then
  what="The prod apply is held for a manual dispatch"
elif [ "${CHECK_RESULT:-}" = failure ]; then
  what="The prod apply passed, but nixie's API check after it failed"
else
  what="The prod apply failed"
fi
reference="$(sed -n 's/^ALERT_WEBHOOK_URL=//p' "$file")"
if [ -z "$reference" ]; then
  echo "alert-prod-apply: $file sets no ALERT_WEBHOOK_URL" >&2
  exit 1
fi
# op answers an empty token with only "error initializing client: ", as on the prod environment's
# first runs, before its secret was set
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  echo "alert-prod-apply: OP_SERVICE_ACCOUNT_TOKEN is empty; set the prod environment's secret to the deploy account's token" >&2
  exit 1
fi
url="$(op read --no-newline "$reference")"
echo "::add-mask::$url"
jq -n --arg content "$what: $RUN_URL" '{content: $content}' |
  curl -fsS -H 'Content-Type: application/json' --data @- "$url" > /dev/null
