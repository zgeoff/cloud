#!/usr/bin/env bash
# Regenerate the Onidel TypeScript SDK from the provider binary, then build it to
# sdk/onidel/bin so infra/ typechecks against its .d.ts files, not its sources. The SDK's version
# is the schema's, which is the provider's Version in cmd/pulumi-resource-onidel/main.go, and its
# @pulumi/pulumi dependency is infra's pin, so the repo has one of each.
set -euo pipefail

bun run provider:build
rm -rf sdk/onidel sdk/.gen
pulumi package gen-sdk ./provider/bin/pulumi-resource-onidel --language nodejs --out sdk/.gen
mv sdk/.gen/nodejs sdk/onidel
rm -rf sdk/.gen
pin="$(jq -r '.dependencies["@pulumi/pulumi"]' infra/package.json)"
jq --arg pin "$pin" '.main = "bin/index.js" | .types = "bin/index.d.ts" | .dependencies["@pulumi/pulumi"] = $pin' \
  sdk/onidel/package.json > sdk/onidel/package.json.tmp
mv sdk/onidel/package.json.tmp sdk/onidel/package.json
bun install
bun run sdk:build
