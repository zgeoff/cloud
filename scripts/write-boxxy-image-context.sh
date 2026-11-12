#!/usr/bin/env bash
# Write the boxxy image's build context into <dir>: the boxxy server compiled for linux-x64 to one
# binary, ./boxxy-server, with `bun build --compile` from deploy/boxxy/server.ts, the live rules
# from deploy/boxxy/rules as ./rules, and images/boxxy/Dockerfile beside them. The binary links
# glibc, which the distroless cc base holds, and carries bun:sqlite inside it. Run it after
# `bun install`, since the compile bundles @boxxy/server and its dependencies from node_modules.
# package.json names @pepys/kit, a required peer of @boxxy/pepys, so the install puts it there;
# nothing here imports it, so knip.json ignores it.
#
#   bash scripts/write-boxxy-image-context.sh <dir>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" != 1 ]; then
  echo "usage: write-boxxy-image-context.sh <dir>" >&2
  exit 2
fi
context="$1"
mkdir -p "$context"
bun build --compile --minify --target=bun-linux-x64 deploy/boxxy/server.ts --outfile "$context/boxxy-server"
rm -rf "$context/rules"
cp -R deploy/boxxy/rules "$context/rules"
cp images/boxxy/Dockerfile "$context/"
