#!/usr/bin/env bash
# The atc-gateway fixture test: it checks the fixture-image wrapper (the fixture-images group),
# then runs the gateway, backup and restore suites (the atc-gateway-fixture group) against the
# fixture images. scripts/run-bats.sh finds each group's suites by the
# `# bats file_tags=suite:<group>` line in their headers. The atc-gateway images workflow runs it on a
# change to any file it reads.
#
#   bash images/atc-gateway/run-fixture-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
bash scripts/run-bats.sh fixture-images
bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
