#!/usr/bin/env bash
# Checks out the deployed revision beside the prod apply job's checkout, for the drift check from
# it: a detached git worktree of DEPLOYED (the commit the deployed/prod tag held when the decide
# job ran) at $RUNNER_TEMP/deployed, its .env pointed at the deploy vault with this checkout's
# write-deploy-env.sh, and its dependencies installed with `bun install --frozen-lockfile` there.
#
# A failed worktree add, env rewrite or install fails the run with that command's status, so the
# drift check never runs on a half-made checkout. A missing RUNNER_TEMP or DEPLOYED is a usage
# error (exit 2).
#
#   RUNNER_TEMP=<dir> DEPLOYED=<commit> bash scripts/check-out-deployed-revision.sh
#
# It runs in the job's checkout.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in RUNNER_TEMP DEPLOYED; do
  if [ -z "${!name:-}" ]; then
    echo "check-out-deployed-revision: set $name" >&2
    exit 2
  fi
done

git worktree add --detach "$RUNNER_TEMP/deployed" "$DEPLOYED"
bash "$here/write-deploy-env.sh" "$RUNNER_TEMP/deployed/.env"
cd "$RUNNER_TEMP/deployed"
bun install --frozen-lockfile
