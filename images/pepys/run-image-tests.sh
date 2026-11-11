#!/usr/bin/env bash
# The pepys image test: it writes a stand-in build context, builds images/pepys/Dockerfile on the
# pinned distroless base under a tag that carries a random per-run id, runs the pepys-image suites
# (images/pepys/test-pepys-image.sh) with PEPYS_IMAGE and PEPYS_RUN set, and removes the image and
# the context after. When the build fails it prints the build log and exits 1.
#
# The context holds a probe, compiled with `bun build --compile` as ingest and the API are, in
# place of each of the three programs, and a consumers.json and one module of known bytes. So the
# test needs no pepys release, and it proves what the Dockerfile adds: the modes, the user, and a
# compiled program that starts on the base.
#
#   bash images/pepys/run-image-tests.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# sets BASE_IMAGE, among the pins
# shellcheck source=/dev/null
source images/atc-gateway/versions.env
PEPYS_RUN="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
PEPYS_IMAGE="cloud-pepys:test-$PEPYS_RUN"
export PEPYS_RUN PEPYS_IMAGE
work="$(mktemp -d)"
trap 'docker rmi -f "$PEPYS_IMAGE" > /dev/null 2>&1 || true; rm -rf "$work" || true' EXIT

# the probe prints its uid and gid, then for each path it is given the owner, the mode and, for a
# file, the bytes, as one JSON object
cat > "$work/probe.ts" << 'PROBE'
import { readFileSync, statSync } from 'node:fs';

const paths = process.argv.slice(2);
const entries = paths.map((path) => {
  const stat = statSync(path);
  const mode = (stat.mode & 0o7777).toString(8);

  const owner = stat.uid;

  return [path, stat.isFile() ? { owner, mode, text: readFileSync(path, 'utf8') } : { owner, mode }];
});

console.log(JSON.stringify({ uid: process.getuid?.(), gid: process.getgid?.(), paths: Object.fromEntries(entries) }));
PROBE
mkdir -p "$work/context/modules/ledger"
cp images/pepys/Dockerfile "$work/context/"
echo '{"consumers":[{"name":"ledger","module":"ledger/0123abcd.wasm"}]}' > "$work/context/modules/consumers.json"
printf 'module bytes for the image test\n' > "$work/context/modules/ledger/0123abcd.wasm"
# shellcheck disable=SC2153 # BASE_IMAGE comes from versions.env
if ! {
  bun build --compile --target=bun-linux-x64 "$work/probe.ts" --outfile "$work/context/pepys-host" &&
    cp "$work/context/pepys-host" "$work/context/pepys-ingest" &&
    cp "$work/context/pepys-host" "$work/context/pepys-api" &&
    docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$PEPYS_IMAGE" "$work/context"
} > "$work/build.log" 2>&1; then
  echo "FAIL the pepys image did not build"
  sed 's/^/    /' "$work/build.log"
  exit 1
fi
echo "built $PEPYS_IMAGE"
bash scripts/run-shell-suites.sh pepys-image
