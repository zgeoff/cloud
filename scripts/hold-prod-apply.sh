#!/usr/bin/env bash
# Holds the prod apply for a manual dispatch: it prints the GitHub Actions error line that tells
# a person how to apply the held plan, then exits 1 so the run fails and the alert job reports
# the hold. The Deploy prod workflow runs it when the guard holds a run it did not start by hand.
# A missing or extra argument is a usage error (exit 2).
#
#   bash scripts/hold-prod-apply.sh <revision>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: hold-prod-apply.sh <revision>" >&2
  exit 2
fi

echo "::error::The guard held the apply. To apply this plan, dispatch Deploy prod on main with revision $1."
exit 1
