#!/usr/bin/env bash
# Write the files image's build context into <dir>: the service compiled for linux-x64 to one
# binary, ./files, with `bun build --compile`, and images/files/Dockerfile beside it. The binary
# links glibc, which the distroless cc base holds. Run it after `bun install`, since the compile
# bundles the service's dependencies from node_modules.
#
#   bash scripts/write-files-image-context.sh <dir>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" != 1 ]; then
  echo "usage: write-files-image-context.sh <dir>" >&2
  exit 2
fi
context="$1"
mkdir -p "$context"
bun build --compile --minify --target=bun-linux-x64 packages/files/main.ts --outfile "$context/files"
cp images/files/Dockerfile "$context/"
