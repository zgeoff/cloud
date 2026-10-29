#!/usr/bin/env bash
# Refuse a host switch whose impd stores a secret kind that the host's atc daemon does not accept.
# switch-geoffcloud.sh runs it before the build, with the configuration.nix and the atc.nix of the
# commit it switches to:
#
#   bash scripts/check-atc-secret-kinds.sh <configuration.nix> <atc.nix>
#
# atc's auth binding compares each brokered secret's kind with the kind it expects, so a kind that
# atc does not know fails every spawn and adopt with auth_secret_mismatch: impd 5.0.0 stores
# `static`, which atc 7.3.0 lacks. The impd release is the imp-host image's tag, and impd's kinds
# are its SecretKindSchema enum, in packages/api/src/schemas/secret-schema.ts of zgeoff/impz at the
# release's tag. atc's kinds are its BrokerSecretKind union, in
# packages/plugin-api/src/credential-broker.ts of zgeoff/atc at the pin's tag. The check reads both
# files through gh.
# It prints one line and exits 0 when atc accepts every kind impd stores. It exits 1 when atc lacks
# one, when a pin holds no release version, or when a file holds no one kind list; a gh failure
# stops it with gh's exit code.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: check-atc-secret-kinds.sh <configuration.nix> <atc.nix>" >&2
  exit 2
fi
config="$1"
nix="$2"
version='[0-9]+\.[0-9]+\.[0-9]+'

for file in "$config" "$nix"; do
  if [ ! -f "$file" ]; then
    echo "$file is missing, so the switch has no pin to compare secret kinds by" >&2
    exit 1
  fi
done
# the one services.imp.image line, as the imp release bump writes it
impd="$(sed -nE "s/^ +image = \"ghcr\.io\/zgeoff\/imp-host:($version)@sha256:[0-9a-f]{64}\";\$/\\1/p" "$config")"
if [[ ! "$impd" =~ ^$version$ ]]; then
  echo "$config pins no imp-host release image" >&2
  exit 1
fi
# the one `version = "X.Y.Z";` line, as the atc release bump writes it
atc="$(sed -nE "s/^  version = \"($version)\";\$/\\1/p" "$nix")"
if [[ ! "$atc" =~ ^$version$ ]]; then
  echo "$nix pins no atc release version" >&2
  exit 1
fi

# impd's one line, `export const SecretKindSchema = z.enum(['static', 'oauth']);`
schema="$(gh api -H 'Accept: application/vnd.github.raw' \
  "repos/zgeoff/impz/contents/packages/api/src/schemas/secret-schema.ts?ref=v$impd")"
stored="$(sed -nE "s/^export const SecretKindSchema = z\.enum\(\[('[a-z]+'(, '[a-z]+')*)\]\);\$/\\1/p" <<< "$schema")"
if [[ ! "$stored" =~ ^\'[a-z] ]] || [ "$(wc -l <<< "$stored")" != 1 ]; then
  echo "impd $impd's secret-schema.ts names no one SecretKindSchema enum" >&2
  exit 1
fi
read -ra stored_kinds <<< "$(tr -d "'," <<< "$stored")"

# atc's one line, `export type BrokerSecretKind = 'anthropic' | 'custom' | 'oauth';`
broker="$(gh api -H 'Accept: application/vnd.github.raw' \
  "repos/zgeoff/atc/contents/packages/plugin-api/src/credential-broker.ts?ref=%40zgeoff/atc%40$atc")"
accepted="$(sed -nE "s/^export type BrokerSecretKind = ('[a-z]+'( \| '[a-z]+')*);\$/\\1/p" <<< "$broker")"
if [[ ! "$accepted" =~ ^\'[a-z] ]] || [ "$(wc -l <<< "$accepted")" != 1 ]; then
  echo "atc $atc's credential-broker.ts names no one BrokerSecretKind union" >&2
  exit 1
fi
read -ra accepted_kinds <<< "$(tr -d "'|" <<< "$accepted")"

missing=()
for kind in "${stored_kinds[@]}"; do
  if [[ " ${accepted_kinds[*]} " != *" $kind "* ]]; then missing+=("$kind"); fi
done
if [ "${#missing[@]}" != 0 ]; then
  lacked="${missing[*]}"
  known="${accepted_kinds[*]}"
  noun=kind
  if [ "${#missing[@]}" -gt 1 ]; then noun=kinds; fi
  echo "the switch would run impd $impd, which stores the secret $noun ${lacked// /, }, but atc" \
    "$atc on the host accepts ${known// /, } only; pin an atc that accepts ${lacked// /, }" \
    "first (nixos/packages/atc.nix)" >&2
  exit 1
fi
kinds="${stored_kinds[*]}"
echo "== impd $impd stores the secret kinds ${kinds// /, }, which atc $atc accepts"
