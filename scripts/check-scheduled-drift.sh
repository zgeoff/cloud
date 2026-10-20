#!/usr/bin/env bash
# The scheduled drift check: a refresh of the prod stack that only previews, so it compares each
# resource's live state with the state file and changes neither. It runs
# `pulumi refresh --preview-only --expect-no-changes` in infra/, through retry-transient-pulumi.sh,
# so an ACME server's 5xx or a failed plugin download runs it again. A refresh that does not run
# the program needs no program input, only the state, the passphrase and each refreshed provider's
# credentials, which scripts/run-host-drift-check.sh loads from the host's credentials file.
#
# It leaves out every Onidel and every Kubernetes resource (--exclude), because without the program
# Pulumi configures each provider from the state, not from the environment: Onidel's from the
# full-account key the state holds, and Kubernetes's from the admin kubeconfig, over the tailnet.
# docs/runbooks/drift-check.md gives the reasons and what the check covers.
#
# It writes clean, drift or failed to $OUTCOME_FILE, for the alert, and exits with the refresh's
# status. Pulumi exits 7 (ExitNoChanges, part of its stable exit-code contract) when the refresh
# found a change, which is drift; any other non-zero status is a check that failed. Extra arguments
# pass to pulumi, such as --suppress-outputs. A missing OUTCOME_FILE is a usage error (exit 2).
#
#   OUTCOME_FILE=<file> bash scripts/check-scheduled-drift.sh [pulumi argument…]
set -euo pipefail

if [ -z "${OUTCOME_FILE:-}" ]; then
  echo "check-scheduled-drift: set OUTCOME_FILE" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=0
bash "$root/scripts/retry-transient-pulumi.sh" -C "$root/infra" \
  pulumi refresh --stack prod --preview-only --expect-no-changes --non-interactive \
  --exclude 'urn:pulumi:prod::geoff-cloud::**onidel:index:**' \
  --exclude 'urn:pulumi:prod::geoff-cloud::**kubernetes:**' \
  "$@" || status=$?

case "$status" in
  0) outcome=clean ;;
  7) outcome=drift ;;
  *) outcome=failed ;;
esac
echo "$outcome" > "$OUTCOME_FILE"
exit "$status"
