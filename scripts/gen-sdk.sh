#!/usr/bin/env bash
# Regenerate the Onidel TypeScript SDK from the provider binary, then build it to
# sdk/onidel/bin so infra/ typechecks against its .d.ts files, not its sources.
set -euo pipefail

bun run provider:build
rm -rf sdk/onidel sdk/.gen
pulumi package gen-sdk ./provider/bin/pulumi-resource-onidel --language nodejs --version 0.1.0 --out sdk/.gen
mv sdk/.gen/nodejs sdk/onidel
rm -rf sdk/.gen
jq '.main = "bin/index.js" | .types = "bin/index.d.ts"' sdk/onidel/package.json > sdk/onidel/package.json.tmp
mv sdk/onidel/package.json.tmp sdk/onidel/package.json
bun run sdk:build
