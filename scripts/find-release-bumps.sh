#!/usr/bin/env bash
# Print one line for each of atc, imp and nixie whose newest release is newer than a pin in the
# checkout: `<dependency> <newest version> <pinned version>...`, with every pinned version in a
# fixed order, and nothing when every pin is current. Run it from the root of a zgeoff/cloud
# checkout with gh signed in; the release check workflow's check job runs it, and its bump job
# passes each line to scripts/bump-release.sh.
#
#   bash scripts/find-release-bumps.sh
#
# | Dependency | Newest release              | Pins, in order                                                    |
# | ---------- | --------------------------- | ----------------------------------------------------------------- |
# | atc        | zgeoff/atc `@zgeoff/atc@X`  | agent image, host daemon (nixos/packages/atc.nix), versions.env   |
# | imp        | zgeoff/imp `vX`             | imp-host (configuration.nix), imp-base (images/agent/Dockerfile)  |
# | nixie      | zgeoff/nixie `vX`           | nixie, nixie-web (infra/Pulumi.prod.yaml)                         |
#
# The newest release is the highest version among the latest 30 releases that are neither drafts
# nor prereleases. imp's flake input is not read: it moves with imp-host. A pin that is missing, or
# that more than one line holds, fails the run, as does a repository with no release.
set -euo pipefail

# read_pin <file> <pattern>: prints what the one line matching the extended regex captures, or
# fails unless exactly one line matches
read_pin() {
  local lines count
  lines="$(grep -E "$2" "$1" || true)"
  count="$(grep -c . <<< "$lines" || true)"
  if [ "$count" != 1 ]; then
    echo "$1 has $count lines that match '$2', want 1" >&2
    exit 1
  fi
  sed -E "s|$2|\\1|" <<< "$lines"
}

# read_newest <repo> <tag prefix>: prints the highest X.Y.Z among the repository's latest 30
# published releases whose tag is <tag prefix>X.Y.Z
read_newest() {
  local tags newest
  tags="$(gh release list -R "zgeoff/$1" --exclude-drafts --exclude-pre-releases --limit 30 \
    --json tagName --jq '.[].tagName')"
  newest="$(sed -nE "s|^$2([0-9]+\\.[0-9]+\\.[0-9]+)\$|\\1|p" <<< "$tags" | sort -V | tail -1)"
  if [ -z "$newest" ]; then
    echo "zgeoff/$1 has no release tagged $2X.Y.Z" >&2
    exit 1
  fi
  echo "$newest"
}

# print_bump <dependency> <newest> <pinned>...: prints the line when a pin is older than <newest>
print_bump() {
  local pin
  for pin in "${@:3}"; do
    if [ "$pin" != "$2" ] && [ "$(printf '%s\n' "$pin" "$2" | sort -V | tail -1)" = "$2" ]; then
      echo "$*"
      return
    fi
  done
}

version='([0-9]+\.[0-9]+\.[0-9]+)'
atc_agent="$(read_pin images/agent/Dockerfile "^ARG ATC_VERSION=$version\$")"
atc_daemon="$(read_pin nixos/packages/atc.nix "^  version = \"$version\";\$")"
atc_gateway="$(read_pin deploy/atc-gateway/versions.env "^ATC_RELEASE=@zgeoff/atc@$version\$")"
imp_host="$(read_pin nixos/hosts/geoffcloud/configuration.nix \
  "^    image = \"ghcr\\.io/zgeoff/imp-host:$version@sha256:[0-9a-f]{64}\";\$")"
imp_base="$(read_pin images/agent/Dockerfile "^FROM ghcr\\.io/zgeoff/imp-base:$version@sha256:[0-9a-f]{64}\$")"
nixie="$(read_pin infra/Pulumi.prod.yaml "^ +image: ghcr\\.io/zgeoff/nixie:$version@sha256:[0-9a-f]{64}\$")"
nixie_web="$(read_pin infra/Pulumi.prod.yaml "^ +webImage: ghcr\\.io/zgeoff/nixie-web:$version@sha256:[0-9a-f]{64}\$")"

atc="$(read_newest atc @zgeoff/atc@)"
imp="$(read_newest imp v)"
nixie_newest="$(read_newest nixie v)"

print_bump atc "$atc" "$atc_agent" "$atc_daemon" "$atc_gateway"
print_bump imp "$imp" "$imp_host" "$imp_base"
print_bump nixie "$nixie_newest" "$nixie" "$nixie_web"
