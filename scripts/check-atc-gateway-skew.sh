#!/usr/bin/env bash
# Refuse a host switch that would leave the deployed atc gateway on a daemon protocol the host's
# atc daemon no longer speaks. switch-geoffcloud.sh runs it before the build, with the atc.nix of
# the commit it switches to and the image of the gateway Deployment that the cluster runs:
#
#   bash scripts/check-atc-gateway-skew.sh <atc.nix> <gateway image>
#
# It prints one line and exits 0 when the daemon pin and the gateway image share an atc major
# version, and exits 1 when they differ, or when either holds no atc release version. The daemon
# handshake cannot catch the skew: atc 4.0.0 renamed `report.get` to `note.get`, and its protocol
# version (PROTOCOL_V) stayed 4 from 2.26.2 to 4.5.0. atc names a protocol break as a major
# release (its CHANGELOG.md: 2.0.0 renamed every wire event, 4.0.0 renamed `report.get`), so
# a minor or patch apart, such as daemon 2.26.2 beside gateway 2.27.0, still switches.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: check-atc-gateway-skew.sh <atc.nix> <gateway image>" >&2
  exit 2
fi
nix="$1"
image="$2"
version='([0-9]+)\.[0-9]+\.[0-9]+'

if [ ! -f "$nix" ]; then
  echo "$nix is missing, so the switch has no atc daemon pin to compare" >&2
  exit 1
fi
# the one `version = "X.Y.Z";` line, as pin-atc.sh writes it
daemon="$(sed -nE "s/^  version = \"($version)\";\$/\\1/p" "$nix")"
if [[ ! "$daemon" =~ ^$version$ ]]; then
  echo "$nix pins no atc release version" >&2
  exit 1
fi
daemon_major="${BASH_REMATCH[1]}"

# GATEWAY_IMAGE_TAG is the gateway's atc release (deploy/atc-gateway/versions.env)
if [[ ! "$image" =~ ^ghcr\.io/zgeoff/atc-gateway:($version)(@sha256:[0-9a-f]{64})?$ ]]; then
  echo "the deployed atc gateway runs '$image', which is no atc-gateway release image" >&2
  exit 1
fi
gateway="${BASH_REMATCH[1]}"
gateway_major="${BASH_REMATCH[2]}"

if [ "$daemon_major" != "$gateway_major" ]; then
  echo "the switch would run atc $daemon on the host, but the deployed atc gateway runs atc" \
    "$gateway, and atc changes its daemon protocol in a major release; deploy an" \
    "atc-gateway $daemon_major.x image first (docs/runbooks/workflows.md, Switch the host)" >&2
  exit 1
fi
echo "== atc $daemon on the host, $gateway in the gateway"
