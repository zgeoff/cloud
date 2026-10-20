#!/usr/bin/env bash
# The prod apply job's refresh before the apply: it builds the provider in PROGRAM, the checkout of
# the revision to apply, then refreshes the prod stack in PROGRAM/infra with
# `pulumi refresh --yes --skip-preview --suppress-outputs` through retry-transient-pulumi.sh, which
# runs it again after an ACME server's 5xx, a Cloudflare API 5xx to a read or a failed plugin
# download. A refresh writes only what it reads into the state and changes no resource, so a second
# try is safe. It names the refresh command itself rather than a package script of PROGRAM, so it
# also refreshes a revision older than this script. A failed provider build fails with its status
# before the refresh. A missing PROGRAM is a usage error (exit 2).
#
#   PROGRAM=<dir> bash scripts/refresh-prod.sh
#
# It passes its environment, the deploy vault's OP_SERVICE_ACCOUNT_TOKEN among it, to op. It runs
# in the checkout of the workflow's own revision.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${PROGRAM:-}" ]; then
  echo "refresh-prod: set PROGRAM" >&2
  exit 2
fi

(cd "$PROGRAM" && bun run provider:build)
bash "$here/retry-transient-pulumi.sh" -C "$PROGRAM/infra" \
  op run --env-file=../.env -- pulumi refresh --stack prod --yes --skip-preview --suppress-outputs
