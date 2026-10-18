# shellcheck shell=bash
# start_alertmanager <dir> <config dir>: starts the pinned Alertmanager in Docker on the host
# network, with <config dir>/alertmanager.json as its config and <config dir> mounted read-only at
# /config, clustering off, and returns once it reports ready. <dir>/url then holds its loopback URL,
# and <dir>/container the container to remove when the case ends. The image is the one
# kube-prometheus-stack's values pin for the chart version in
# infra/observability/create-metrics.ts, and it runs as uid 65532 on a read-only root with no
# capabilities and no privilege escalation.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/pick-port.sh"

start_alertmanager() {
  local dir="$1" port container
  local image='quay.io/prometheus/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a'
  port="$(pick_port)"
  container="alertmanager-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  echo "$container" > "$dir/container"
  echo "http://127.0.0.1:$port" > "$dir/url"
  docker pull -q "$image" > /dev/null
  docker run -d --name "$container" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$2:/config:ro" "$image" \
    --config.file=/config/alertmanager.json --storage.path=/tmp/alertmanager \
    --web.listen-address="127.0.0.1:$port" --cluster.listen-address= > /dev/null
  wait_for 60 "Alertmanager to report ready" curl -q --noproxy '*' -fs -o /dev/null "http://127.0.0.1:$port/-/ready"
}
