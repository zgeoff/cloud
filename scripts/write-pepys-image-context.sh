#!/usr/bin/env bash
# Write the cloud-pepys image's build context into <dir>: the pinned host binary, the deployment's
# consumer modules from `pepys build`, ingest and the API compiled for linux-x64 with
# `bun build --compile`, and images/pepys/Dockerfile. Run it after `bun install`, since the build
# and the compiles read the @pepys/* packages from node_modules.
#
#   bash scripts/write-pepys-image-context.sh <dir>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" != 1 ]; then
  echo "usage: write-pepys-image-context.sh <dir>" >&2
  exit 2
fi
context="$1"
mkdir -p "$context"
bash scripts/fetch-pepys-release.sh "$context"
bun x pepys build deploy/pepys/deployment.ts --out "$context/modules"
bun build --compile --minify --target=bun-linux-x64 deploy/pepys/ingest.ts --outfile "$context/pepys-ingest"
bun build --compile --minify --target=bun-linux-x64 deploy/pepys/api.ts --outfile "$context/pepys-api"
cp images/pepys/Dockerfile "$context/"
