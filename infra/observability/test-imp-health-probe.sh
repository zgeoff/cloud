#!/usr/bin/env bash
# Test for imp's health probe in the real engine: impd's /health body served from the case tree
# over loopback, and the pinned blackbox exporter running the imp_health module that
# imp-health-probe-values.ts builds. The exporter is the version the chart in blackbox-chart.ts
# runs (its appVersion). Each case compares the measured probe_success. The fixture serves plain
# HTTP on loopback, so the case turns the module's fail_if_not_ssl off and keeps every other field
# as built; the module's own test pins fail_if_not_ssl on.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='not JSON' bash infra/observability/test-imp-health-probe.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
blackbox_image='quay.io/prometheus/blackbox-exporter:v0.28.0@sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc'
run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"

# setup_test <tree>: the exporter's config, as JSON from the repo's builder, a file server over the
# case tree, and the exporter on the host network, both on loopback ports
setup_test() {
  local tree="$1"
  mkdir -p "$tree/www" "$tree/config"
  web_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  exporter_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  url="http://127.0.0.1:$web_port/health"
  (cd "$repo" && TREE="$tree" bun -e "
    import { impHealthProbeValues } from './infra/observability/imp-health-probe-values.ts';
    const config = structuredClone(impHealthProbeValues.config);
    config.modules.imp_health.http.fail_if_not_ssl = false;
    await Bun.write((process.env.TREE ?? '') + '/config/blackbox.json', JSON.stringify(config));
  ")
  # pulled here, so a cold image cache never writes its progress into a case's compared output
  docker pull -q "$blackbox_image" > /dev/null
  python3 -m http.server --bind 127.0.0.1 --directory "$tree/www" "$web_port" > "$tree/www.log" 2>&1 &
  server_pid=$!
  container="imp-health-exporter-$run_id-$BASHPID"
  docker run -d --name "$container" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges -v "$tree/config:/config:ro" "$blackbox_image" \
    --config.file=/config/blackbox.json --web.listen-address="127.0.0.1:$exporter_port" > /dev/null
  wait_for 60 "the blackbox exporter" curl -fs -o /dev/null "http://127.0.0.1:$exporter_port/-/healthy"
  wait_for 10 "the file server" curl -fs -o /dev/null "http://127.0.0.1:$web_port/"
}

# teardown: each step safe when setup_test stopped before it
teardown() {
  if [ -n "${container:-}" ]; then docker rm -f "$container" > /dev/null 2>&1 || true; fi
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2> /dev/null || true; fi
  rm -rf "$tree" || true
}

# read_probe_success <tree> <body>: serves the body as impd's /health and prints the exporter's
# probe_success for it
read_probe_success() {
  printf '%s' "$2" > "$1/www/health"
  curl -fsS "http://127.0.0.1:$exporter_port/probe?module=imp_health&target=$url" > "$1/probe.txt"
  sed -n 's/^probe_success \([01]\)$/\1/p' "$1/probe.txt"
}

# impd's /health body as its daemon serves it: { status: 'ok', ready: deps.isReady() } as JSON
# (zgeoff/impz packages/daemon/src/build-app.ts at 51df459d), with the warnings it lists
it_passes_a_body_whose_ready_is_true() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  assert_equals 1 "$(read_probe_success "$tree" '{"status":"ok","ready":true,"warnings":[]}')" "probe_success"
}

it_passes_a_ready_body_that_JSON_spaces_over_lines() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  assert_equals 1 "$(read_probe_success "$tree" $'{\n  "status": "ok",\n  "ready": true\n}\n')" "probe_success"
}

it_fails_a_body_whose_ready_is_false() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  assert_equals 0 "$(read_probe_success "$tree" '{"status":"ok","ready":false}')" "probe_success"
}

it_fails_a_body_without_ready() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  assert_equals 0 "$(read_probe_success "$tree" '{"status":"ok"}')" "probe_success"
}

it_fails_a_body_that_names_ready_true_but_is_not_JSON() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  assert_equals 0 "$(read_probe_success "$tree" '<p>"ready":true</p>')" "probe_success"
}

run_cases
