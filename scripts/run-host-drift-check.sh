#!/usr/bin/env bash
# The scheduled drift check's run on geoffcloud, which drift-check.service starts each day
# (nixos/modules/drift-check.nix). It loads the check's credentials, waits while a Deploy prod run
# is in progress, runs check-scheduled-drift.sh, and posts drift or a failed run to Discord with
# alert-scheduled-drift.sh. It exits 0 when the check finds no drift, and otherwise with the
# check's status, or 1 for a run that never reached the check.
#
# The credentials come from the file `drift-check` in systemd's $CREDENTIALS_DIRECTORY, one
# KEY=VALUE line for each name in `names` below. A line with another name, a line with no `=`, or a
# missing or empty name fails the run before the check. The check gets each credential but the
# webhook, in its environment, never on a command line, and the alert gets only the webhook. It
# never prints a value.
#
# A Deploy prod run writes the state that the check reads, so a check during one would report the
# apply's own changes as drift. It asks GitHub's API, anonymously, for the newest Deploy prod runs
# of REPO, and while one of them is queued or in progress, it pauses DEPLOY_WAIT_DELAY seconds
# (default 300) and asks again, up to DEPLOY_WAIT_ATTEMPTS asks (default 6). A run still in progress
# after the last ask fails the run. When GitHub does not answer, it says so on stderr and checks
# anyway, because a missed check hides drift for a day and an unneeded alert costs a re-run.
#
# GitHub's concurrency group cannot hold this service, so a Deploy prod run can still start during
# the refresh. A check that fails therefore asks again: when a Deploy prod run is queued or in
# progress, or changed since the check started, it waits as before and runs the check once more,
# and reports that second check. This is a guard after the fact, not a lock: a clean check that
# overlapped an apply reports clean.
#
# The check runs under timeout, for CHECK_TIMEOUT seconds (default 2700), so a hung refresh ends
# as a failed check that posts its alert, not as a unit that systemd kills without one. The alert
# names where to read the run: `journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=<id>` on
# RUN_HOST, from systemd's INVOCATION_ID. A failed alert prints its status on stderr and leaves
# the exit status as the check's. An argument is a usage error (exit 2).
#
#   CREDENTIALS_DIRECTORY=<dir> INVOCATION_ID=<id> RUN_HOST=<host> GITHUB_API_URL=<url> \
#     REPO=<owner/name> [DEPLOY_WAIT_ATTEMPTS=<n>] [DEPLOY_WAIT_DELAY=<seconds>] \
#     [CHECK_TIMEOUT=<seconds>] bash scripts/run-host-drift-check.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: run-host-drift-check.sh" >&2
  exit 2
fi
for name in CREDENTIALS_DIRECTORY INVOCATION_ID RUN_HOST GITHUB_API_URL REPO; do
  if [ -z "${!name:-}" ]; then
    echo "run-host-drift-check: set $name" >&2
    exit 2
  fi
done
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attempts="${DEPLOY_WAIT_ATTEMPTS:-6}"
delay="${DEPLOY_WAIT_DELAY:-300}"
check_timeout="${CHECK_TIMEOUT:-2700}"
run_ref="on $RUN_HOST: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=$INVOCATION_ID"

names=(
  PULUMI_BACKEND_URL
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  PULUMI_CONFIG_PASSPHRASE
  CLOUDFLARE_API_TOKEN
  TAILSCALE_OAUTH_CLIENT_ID
  TAILSCALE_OAUTH_CLIENT_SECRET
  TAILSCALE_TAILNET
  ALERT_WEBHOOK_URL
)
declare -A credentials=() known=()
for name in "${names[@]}"; do known[$name]=1; done

# alert <outcome>: posts the alert with the webhook alone in its environment
alert() {
  local status=0
  (
    export ALERT_WEBHOOK_URL="${credentials[ALERT_WEBHOOK_URL]:-}"
    OUTCOME="$1" RUN_REF="$run_ref" bash "$root/scripts/alert-scheduled-drift.sh"
  ) || status=$?
  if [ "$status" != 0 ]; then
    echo "run-host-drift-check: the alert failed (exit $status)" >&2
  fi
}

# fail_run <message>: ends a run that never reached the check, with its alert
fail_run() {
  echo "run-host-drift-check: $1" >&2
  alert ""
  exit 1
}

file="$CREDENTIALS_DIRECTORY/drift-check"
if [ ! -r "$file" ]; then
  fail_run "no credentials file at $file"
fi
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  if [ -z "$line" ]; then continue; fi
  name="${line%%=*}"
  if [ "$name" = "$line" ] || [ -z "$name" ] || [ -z "${known[$name]:-}" ]; then
    fail_run "line $line_number of the credentials file holds no known name"
  fi
  credentials[$name]="${line#*=}"
done < "$file"
missing=()
for name in "${names[@]}"; do
  if [ -z "${credentials[$name]:-}" ]; then missing+=("$name"); fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  fail_run "the credentials file has no ${missing[*]}"
fi

runs_url="$GITHUB_API_URL/repos/$REPO/actions/workflows/deploy-prod.yml/runs?per_page=20"

# wait_for_deploy: returns once no Deploy prod run is queued or in progress, or GitHub does not
# answer, and fails the run after the last ask
wait_for_deploy() {
  local attempt=1 runs active
  while :; do
    if runs="$(curl -fsS --max-time 30 "$runs_url")"; then
      active="$(jq '[.workflow_runs[] | select(.status == "queued" or .status == "in_progress")] | length' <<< "$runs")"
    else
      echo "run-host-drift-check: GitHub did not list the Deploy prod runs; checking anyway" >&2
      active=0
    fi
    if [ "$active" = 0 ]; then return; fi
    if [ "$attempt" -ge "$attempts" ]; then
      fail_run "a Deploy prod run was still in progress after $attempts asks"
    fi
    echo "run-host-drift-check: a Deploy prod run is in progress; asking again in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# overlapped <since>: succeeds when a Deploy prod run is queued or in progress, or changed at or
# after <since>, an ISO 8601 UTC time, so it may have applied during the check; fails when none
# did or GitHub does not answer
overlapped() {
  local runs
  if ! runs="$(curl -fsS --max-time 30 "$runs_url")"; then
    echo "run-host-drift-check: GitHub did not list the Deploy prod runs; reporting the check as it ended" >&2
    return 1
  fi
  jq -e --arg since "$1" 'any(.workflow_runs[]; .status == "queued" or .status == "in_progress" or (.updated_at // "") >= $since)' <<< "$runs" > /dev/null
}

outcome_file="$(mktemp)"
trap 'rm -f "$outcome_file"' EXIT

wait_for_deploy
try=1
while :; do
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status=0
  (
    for name in "${names[@]}"; do
      if [ "$name" != ALERT_WEBHOOK_URL ]; then export "$name=${credentials[$name]}"; fi
    done
    export AWS_REGION=auto OUTCOME_FILE="$outcome_file"
    timeout "$check_timeout" bash "$root/scripts/check-scheduled-drift.sh" --suppress-outputs
  ) || status=$?
  if [ "$status" = 0 ]; then
    echo "run-host-drift-check: no drift"
    exit 0
  fi
  if [ "$try" -ge 2 ] || ! overlapped "$started"; then break; fi
  echo "run-host-drift-check: a Deploy prod run overlapped the check; checking again once it ends" >&2
  wait_for_deploy
  try=2
done
alert "$(cat "$outcome_file")"
exit "$status"
