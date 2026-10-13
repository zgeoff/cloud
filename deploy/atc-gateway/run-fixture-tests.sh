#!/usr/bin/env bash
# The atc-gateway fixture test: it checks the fixture-image wrapper (the fixture-images group),
# then runs the gateway, backup and restore suites (the atc-gateway-fixture group) against the
# fixture images. scripts/run-shell-suites.sh finds each group's suites by the
# `# shell-suite: <group>` line in their headers. The atc-gateway images workflow runs it on a
# change to any file it reads.
#
#   bash deploy/atc-gateway/run-fixture-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
bash scripts/run-shell-suites.sh fixture-images
bash scripts/test-lib/with-fixture-images.sh bash scripts/run-shell-suites.sh atc-gateway-fixture
