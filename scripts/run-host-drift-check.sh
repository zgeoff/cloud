#!/usr/bin/env bash
# The scheduled drift check's run on geoffcloud, which drift-check.service starts each day
# (nixos/modules/drift-check.nix). It loads the check's credentials, makes sure the run holds the
# prod lock, runs check-scheduled-drift.sh, and posts drift or a failed run to Discord with
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
# apply's own changes as drift. Both therefore hold the prod lock (hold-prod-lock.sh) while they
# use the state. The unit takes it as root before this script, with hold-host-prod-lock.sh, which
# writes the take's exit status to LOCK_STATUS_FILE, and releases it after. A status other than 0,
# or no status, fails the run before the check, with the failed alert: 75 when a Deploy prod run
# held the lock past the wait.
#
# The check runs under timeout, for CHECK_TIMEOUT seconds (default 2700), so a hung refresh ends
# as a failed check that posts its alert, not as a unit that systemd kills without one. The alert
# names where to read the run: `journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=<id>` on
# RUN_HOST, from systemd's INVOCATION_ID. A posted alert prints which alert it was on stderr. A
# failed alert prints its status on stderr and leaves the exit status as the check's. Any other step
# that fails once the inputs are set posts the failed alert as the run exits. An argument is a usage
# error (exit 2).
#
#   CREDENTIALS_DIRECTORY=<dir> INVOCATION_ID=<id> RUN_HOST=<host> LOCK_STATUS_FILE=<file> \
#     [CHECK_TIMEOUT=<seconds>] bash scripts/run-host-drift-check.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: run-host-drift-check.sh" >&2
  exit 2
fi
for name in CREDENTIALS_DIRECTORY INVOCATION_ID RUN_HOST LOCK_STATUS_FILE; do
  if [ -z "${!name:-}" ]; then
    echo "run-host-drift-check: set $name" >&2
    exit 2
  fi
done
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

alerted=0

# alert <outcome>: posts the alert with the webhook alone in its environment, and says which alert
# it posted
alert() {
  local status=0 kind=failed
  alerted=1
  if [ "$1" = drift ]; then kind=drift; fi
  (
    export ALERT_WEBHOOK_URL="${credentials[ALERT_WEBHOOK_URL]:-}"
    OUTCOME="$1" RUN_REF="$run_ref" bash "$root/scripts/alert-scheduled-drift.sh"
  ) || status=$?
  if [ "$status" != 0 ]; then
    echo "run-host-drift-check: the alert failed (exit $status)" >&2
  else
    echo "run-host-drift-check: posted the $kind alert" >&2
  fi
}

# finish: on exit, removes the outcome file, and posts the failed alert for a run that fails on a
# step with no alert of its own
outcome_file=
# shellcheck disable=SC2329 # the EXIT trap below invokes it
finish() {
  local status=$?
  if [ -n "$outcome_file" ]; then rm -f "$outcome_file"; fi
  if [ "$status" != 0 ] && [ "$alerted" = 0 ]; then
    echo "run-host-drift-check: the run failed (exit $status)" >&2
    alert ""
  fi
  exit "$status"
}
trap finish EXIT

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

lock_status="$(cat "$LOCK_STATUS_FILE" 2> /dev/null || true)"
case "$lock_status" in
  0) ;;
  75) fail_run "a Deploy prod run held the prod lock past the wait" ;;
  '') fail_run "the run never took the prod lock" ;;
  *) fail_run "taking the prod lock failed (exit $lock_status)" ;;
esac

outcome_file="$(mktemp)"

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
alert "$(cat "$outcome_file")"
exit "$status"
