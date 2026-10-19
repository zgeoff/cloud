#!/usr/bin/env bash
# Install the Pulumi CLI at infra's @pulumi/pulumi pin for the CI job's SDK check and the preview
# test of the port-forward guard, so neither has a pin of its own. It downloads the release
# tarball into RUNNER_TEMP, checks it against the release's checksum file, extracts it there, and
# adds RUNNER_TEMP/pulumi to GITHUB_PATH for the steps after it. A failed download or a checksum
# that does not match fails the step before anything is extracted. It then installs the
# Kubernetes provider plugin at infra's @pulumi/kubernetes pin, which that preview test runs.
#
#   RUNNER_TEMP=… GITHUB_PATH=… bash scripts/install-pulumi-cli.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${RUNNER_TEMP:?set RUNNER_TEMP to the directory the CLI goes in}"
: "${GITHUB_PATH:?set GITHUB_PATH to the file that takes the paths for later steps}"

version="$(jq -r '.dependencies["@pulumi/pulumi"]' infra/package.json)"
manifest="$PWD/infra/package.json"
base="https://get.pulumi.com/releases/sdk"
cd "$RUNNER_TEMP"
curl -fsSLO "$base/pulumi-v$version-linux-x64.tar.gz"
curl -fsSL "$base/pulumi-$version-checksums.txt" |
  grep " pulumi-v$version-linux-x64.tar.gz\$" | sha256sum -c -
tar -xzf "pulumi-v$version-linux-x64.tar.gz"
echo "$RUNNER_TEMP/pulumi" >> "$GITHUB_PATH"
kubernetes="$(jq -er '.dependencies["@pulumi/kubernetes"]' "$manifest")"
"$RUNNER_TEMP/pulumi/pulumi" plugin install resource kubernetes "$kubernetes"
