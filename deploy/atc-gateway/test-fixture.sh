#!/usr/bin/env bash
# The atc-gateway fixture test: it checks the fixture-image wrapper, then runs the gateway, backup
# and restore suites against the fixture images. The atc-gateway images workflow runs it on a
# change to any file it reads, so its suite list lives here, under that workflow's paths, rather
# than in the root package.json.
#
#   bash deploy/atc-gateway/test-fixture.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
bash scripts/test-lib/test-with-fixture-images.sh
bash scripts/test-lib/with-fixture-images.sh bash -c 'bash scripts/test-lib/test-start-gateway.sh && bash scripts/test-lib/test-wait-for-ready.sh && bash scripts/test-lib/test-run-backup.sh && bash scripts/test-lib/test-run-backup-shell.sh && bash deploy/atc-gateway/test-atc-gateway-image.sh && bash deploy/atc-gateway/backup/test-backup.sh && bash e2e/test-atc-gateway-restore.sh'
