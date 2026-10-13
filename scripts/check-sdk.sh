#!/usr/bin/env bash
# Checks that the committed Onidel SDK is what the provider generates: it runs sdk:gen, then fails
# when sdk/onidel/ differs from the index or holds a file git does not track. CI installs the Pulumi
# CLI at infra's @pulumi/pulumi pin; a local CLI at another version gets a warning, because its
# codegen can differ from CI's.
#
#   bash scripts/check-sdk.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

want="v$(jq -r '.dependencies["@pulumi/pulumi"]' infra/package.json)"
have="$(pulumi version)"
if [ "$have" != "$want" ]; then
  echo "warning: Pulumi CLI $have, but CI generates the SDK with $want" >&2
fi

bun run sdk:gen
if ! git diff --exit-code -- sdk/onidel; then
  echo "sdk/onidel is stale: commit the regenerated SDK" >&2
  exit 1
fi
untracked="$(git ls-files --others --exclude-standard -- sdk/onidel)"
if [ -n "$untracked" ]; then
  echo "sdk:gen wrote files git does not track:" >&2
  echo "$untracked" >&2
  exit 1
fi
