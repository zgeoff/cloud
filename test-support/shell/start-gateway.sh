# shellcheck shell=bash
# start_gateway <name> <tree> <image>: runs the gateway image detached as the Deployment
# runs it (infra/build-atc-gateway-spec.ts): a read-only root, no new privileges, every
# capability dropped, the same tmpfs mounts, env and args, the volume <name>-state as its
# state directory, <tree>/registry read-only at /etc/atc-gateway, and port 8414 published
# on an ephemeral loopback port. The container is named <name>; the caller creates the
# volume and removes both. It returns once wait_for_ready does, with 30 seconds for the
# gateway to boot.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for-ready.sh"

start_gateway() {
  local name="$1" tree="$2" image="$3"
  docker run -d --name "$name" --read-only --security-opt no-new-privileges --cap-drop ALL \
    --tmpfs /run/atc:uid=65532,gid=65532 --tmpfs /tmp:exec \
    --tmpfs /home/nonroot/.config:uid=65532,gid=65532 \
    -v "$name-state:/home/nonroot/.local/state/atc" -v "$tree/registry:/etc/atc-gateway:ro" \
    -p 127.0.0.1::8414 -e ATC_GATEWAY_TOKEN_GEOFFCLOUD=fixture-only \
    -e ATC_GATEWAY_STATE_DIR=/home/nonroot/.local/state/atc \
    "$image" serve --host 0.0.0.0 --port 8414 --public-url https://atc.fixture.invalid \
    --registry /etc/atc-gateway/registry.json --state-dir /home/nonroot/.local/state/atc > /dev/null
  wait_for_ready "$name" 30
}
