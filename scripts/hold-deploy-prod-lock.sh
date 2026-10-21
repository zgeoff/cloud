#!/usr/bin/env bash
# The Deploy prod job's hold on the prod lock (hold-prod-lock.sh), before its first Pulumi step and
# after its last. The holder is `deploy-prod <RUN_ID>`, with no attempt, so a re-run of a run whose
# runner died holding the lock takes that hold back rather than waiting for it to run out.
#
# `take` writes the admin kubeconfig from the deploy vault's k3s-kubeconfig item to KUBECONFIG,
# mode 0600, then holds the lock for 6000 s, the job's 100-minute limit, and waits up to 3300 s for
# it, longer than the 3000 s that the scheduled drift check holds it, so a wait ends when the check
# releases it or lets it run out. It exits with hold-prod-lock.sh's status, 75 when the lock stayed
# held. `release` releases the lock and removes the kubeconfig; with no kubeconfig at KUBECONFIG, the
# job never reached the lock, and it does nothing.
#
#   RUN_ID=<id> KUBECONFIG=<file> OP_SERVICE_ACCOUNT_TOKEN=<token> \
#     bash scripts/hold-deploy-prod-lock.sh take|release
set -euo pipefail

if [ "$#" -ne 1 ] || { [ "$1" != take ] && [ "$1" != release ]; }; then
  echo "usage: hold-deploy-prod-lock.sh take|release" >&2
  exit 2
fi
for name in RUN_ID KUBECONFIG; do
  if [ -z "${!name:-}" ]; then
    echo "hold-deploy-prod-lock: set $name" >&2
    exit 2
  fi
done
lock="$(dirname "${BASH_SOURCE[0]}")/hold-prod-lock.sh"
holder="deploy-prod $RUN_ID"

if [ "$1" = release ]; then
  if [ ! -f "$KUBECONFIG" ]; then
    echo "hold-deploy-prod-lock: no kubeconfig at $KUBECONFIG, so the job never took the lock" >&2
    exit 0
  fi
  status=0
  bash "$lock" release "$holder" || status=$?
  rm -f "$KUBECONFIG"
  exit "$status"
fi
written="$(umask 077 && mktemp "$KUBECONFIG.XXXXXX")"
trap 'rm -f "$written"' EXIT
op read --no-newline op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml > "$written"
mv "$written" "$KUBECONFIG"
bash "$lock" take "$holder" 6000 3300
