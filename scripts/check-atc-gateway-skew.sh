#!/usr/bin/env bash
# Refuse a host switch that would leave the running atc gateway on a daemon protocol the host's
# atc daemon no longer speaks. switch-geoffcloud.sh runs it before the build and again before the
# activation, with the atc.nix of the commit it switches to and the image of each atc gateway pod
# that the cluster runs:
#
#   bash scripts/check-atc-gateway-skew.sh <atc.nix> [<gateway image>...]
#
# It prints one line and exits 0 when every gateway image shares the daemon pin's atc major
# version. It exits 1 when one differs, when no gateway pod runs, or when the pin or an image
# holds no atc release version. The daemon handshake cannot catch the skew: atc 4.0.0 renamed
# `report.get` to `note.get`, and its protocol version (PROTOCOL_V) stayed 4 from 2.26.2 to 4.5.0.
# atc names a protocol break as a major release (its CHANGELOG.md: 2.0.0 renamed every wire
# event, 4.0.0 renamed `report.get`), so a minor or patch apart, such as daemon 2.26.2 beside
# gateway 2.27.0, still switches.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: check-atc-gateway-skew.sh <atc.nix> [<gateway image>...]" >&2
  exit 2
fi
nix="$1"
images=("${@:2}")
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

# a gateway rollout recreates the one pod, so between the old pod's end and the new pod's start
# no gateway runs, and the switch cannot tell which atc the next one speaks
if [ "${#images[@]}" = 0 ]; then
  echo "no atc gateway pod runs, so the switch cannot tell which atc it speaks; wait for its" \
    "rollout (kubectl -n atc rollout status deployment atc-gateway)" >&2
  exit 1
fi
gateways=()
for image in "${images[@]}"; do
  # GATEWAY_IMAGE_TAG is the gateway's atc release (images/atc-gateway/versions.env)
  if [[ ! "$image" =~ ^ghcr\.io/zgeoff/atc-gateway:($version)(@sha256:[0-9a-f]{64})?$ ]]; then
    echo "an atc gateway pod runs '$image', which is no atc-gateway release image" >&2
    exit 1
  fi
  gateway="${BASH_REMATCH[1]}"
  if [ "${BASH_REMATCH[2]}" != "$daemon_major" ]; then
    echo "the switch would run atc $daemon on the host, but an atc gateway pod runs atc" \
      "$gateway, and atc changes its daemon protocol in a major release; deploy an" \
      "atc-gateway $daemon_major.x image first (docs/runbooks/workflows.md, Switch the host)" >&2
    exit 1
  fi
  gateways+=("$gateway")
done
echo "== atc $daemon on the host, ${gateways[*]} in the gateway"
