# shellcheck shell=bash
# start_alloy <dir> <config dir> <logs dir> [<storage volume> [<entry script>]]: starts the pinned
# Alloy in Docker on the host network, with <config dir>/config.alloy as its config and <logs dir>
# mounted read-only at /logs, and returns once Alloy reports ready. <dir>/url then holds its loopback
# URL, and <dir>/container the container to remove when the case ends. Alloy keeps its storage, such
# as its read positions, on a tmpfs that ends with the container. Given <storage volume>, it keeps it
# at /storage in that Docker volume instead, which it creates when missing and hands to Alloy's uid,
# so a second start on the same volume resumes from the first's storage; the caller removes the
# volume. Given <entry script>, a POSIX shell script, the container's entry point runs it and then
# execs Alloy, as the chart's command does in production, so a restart of the container runs it
# again. The image is the alloy chart's appVersion (infra/observability/alloy-chart.ts), and it runs
# as production runs it: uid 65532, a read-only root, no capabilities, no privilege escalation. Usage
# reporting is off, so no case reaches Grafana.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/pick-port.sh"

start_alloy() {
  local dir="$1" port container storage_path='/tmp/alloy' storage=() entry=()
  local image='grafana/alloy:v1.20.0@sha256:f111cce835516c5f99166342be7038496b52ced16667be5a11e19258a3e4cd30'
  port="$(pick_port)"
  container="alloy-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  echo "$container" > "$dir/container"
  echo "http://127.0.0.1:$port" > "$dir/url"
  docker pull -q "$image" > /dev/null
  if [ -n "${4:-}" ]; then
    storage_path='/storage'
    storage=(-v "$4:$storage_path")
    docker run --rm --user 0 --entrypoint chown "${storage[@]}" "$image" -R 65532 "$storage_path"
  fi
  if [ -n "${5:-}" ]; then
    # shellcheck disable=SC2016 # expanded by the entry point's sh
    entry=(--entrypoint sh "$image" -c "$5"$'\n''exec /bin/alloy "$@"' alloy)
  else
    entry=("$image")
  fi
  docker run -d --name "$container" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp "${storage[@]}" -v "$2:/config:ro" -v "$3:/logs:ro" \
    "${entry[@]}" run --disable-reporting --server.http.listen-addr="127.0.0.1:$port" \
    --storage.path="$storage_path" /config/config.alloy > /dev/null
  wait_for 60 "Alloy to report ready" curl -q --noproxy '*' -fs -o /dev/null "http://127.0.0.1:$port/-/ready"
}
