#!/usr/bin/env bash
# Checks the repo's one Pulumi pin: the generated Onidel SDK (sdk/onidel/package.json) must depend
# on the same @pulumi/pulumi version as the Pulumi program (infra/package.json). scripts/gen-sdk.sh
# copies infra's pin into the SDK, so a mismatch means a pin changed without a regenerated SDK. It
# prints nothing and exits 0 on a match, and exits 1 with both versions on stderr otherwise,
# including when either file has no pin. The root defaults to this script's repo.
#
#   bash scripts/check-pulumi-pins.sh [<repo root>]
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
infra="$(jq -r '.dependencies["@pulumi/pulumi"] // ""' "$root/infra/package.json")"
sdk="$(jq -r '.dependencies["@pulumi/pulumi"] // ""' "$root/sdk/onidel/package.json")"

if [ -z "$infra" ] || [ "$infra" != "$sdk" ]; then
  echo "@pulumi/pulumi pins differ: infra/package.json has '$infra', sdk/onidel/package.json has '$sdk'" >&2
  echo "change infra's pin, then run: bun run sdk:gen" >&2
  exit 1
fi
