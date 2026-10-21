#!/usr/bin/env bash
# The scheduled drift check's hold on the prod lock (hold-prod-lock.sh), which drift-check.service
# runs as root before and after run-host-drift-check.sh (nixos/modules/drift-check.nix), because
# only root reads k3s's admin kubeconfig. The holder is `drift-check <INVOCATION_ID>`.
#
# `take` holds the lock for 3000 s, the check's 2700 s limit and room for the alert, and waits up to
# 6300 s for it, longer than the 6000 s that a Deploy prod run holds it, so a wait ends when that
# run releases it or lets it run out. It writes hold-prod-lock.sh's exit status to LOCK_STATUS_FILE
# and exits 0, so the check runs and posts the failed alert when the lock was not taken, rather than
# systemd failing the unit with no alert. `release` releases the lock and exits with its status.
#
#   INVOCATION_ID=<id> LOCK_STATUS_FILE=<file> KUBECONFIG=<file> \
#     bash scripts/hold-host-prod-lock.sh take|release
set -euo pipefail

if [ "$#" -ne 1 ] || { [ "$1" != take ] && [ "$1" != release ]; }; then
  echo "usage: hold-host-prod-lock.sh take|release" >&2
  exit 2
fi
for name in INVOCATION_ID LOCK_STATUS_FILE; do
  if [ -z "${!name:-}" ]; then
    echo "hold-host-prod-lock: set $name" >&2
    exit 2
  fi
done
lock="$(dirname "${BASH_SOURCE[0]}")/hold-prod-lock.sh"
holder="drift-check $INVOCATION_ID"

if [ "$1" = release ]; then
  exec bash "$lock" release "$holder"
fi
status=0
bash "$lock" take "$holder" 3000 6300 || status=$?
echo "$status" > "$LOCK_STATUS_FILE"
