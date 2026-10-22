#!/usr/bin/env bash
# The Deploy prod job's step after a cancel or a timeout stopped its refresh or its apply: it clears
# the lock that the stopped step left on the prod stack's Pulumi state, so the next run never fails
# on "the stack is currently locked". It runs
# `op run --env-file=../.env -- pulumi cancel --stack prod --yes` in PROGRAM/infra, the checkout of
# the revision to apply. With no lock on the state, pulumi cancel changes nothing and exits 0.
#
# pulumi cancel ends whatever update holds the Pulumi lock, so the script cancels only while this
# job holds the prod lock (hold-prod-lock.sh check), which no other Deploy prod run or scheduled
# drift check holds at the same time. When the job's lease on the prod lock ran out, it cancels
# nothing and exits 3. With no kubeconfig at KUBECONFIG, the job never reached the prod lock or any
# Pulumi step, and it does nothing. A missing input is a usage error (exit 2).
#
#   RUN_ID=<id> KUBECONFIG=<file> PROGRAM=<dir> OP_SERVICE_ACCOUNT_TOKEN=<token> \
#     bash scripts/cancel-deploy-prod-update.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in RUN_ID KUBECONFIG PROGRAM; do
  if [ -z "${!name:-}" ]; then
    echo "cancel-deploy-prod-update: set $name" >&2
    exit 2
  fi
done

if [ ! -f "$KUBECONFIG" ]; then
  echo "cancel-deploy-prod-update: no kubeconfig at $KUBECONFIG, so the job never took the prod lock" >&2
  exit 0
fi
status=0
bash "$here/hold-prod-lock.sh" check "deploy-prod $RUN_ID" || status=$?
if [ "$status" -ne 0 ]; then
  echo "cancel-deploy-prod-update: the job does not hold the prod lock, so it leaves the Pulumi lock to its holder" >&2
  exit "$status"
fi
cd "$PROGRAM/infra"
op run --env-file=../.env -- pulumi cancel --stack prod --yes
