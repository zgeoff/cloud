#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for the nixie probes, NixieTurnsFailing and NixieDegraded, end to end in the real engines:
# nixie's readiness body served from the case tree over loopback, the pinned blackbox exporter
# running the nixie_turns and nixie_status modules that build-nixie-probe-values.ts builds, and
# promtool testing the rules that build-alert-rules.ts builds against the probe_success the exporter
# measured. The exporter is the version the chart in blackbox-chart.ts runs (its appVersion). Each
# case compares the measured probe_success, and promtool's whole output and exit status.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='fail' bash scripts/run-bats.sh alert-rules

# the first case pulls the images on a cold cache
export BATS_TEST_TIMEOUT=180

blackbox_image='quay.io/prometheus/blackbox-exporter:v0.28.0@sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc'
prometheus_image='quay.io/prometheus/prometheus:v3.7.3@sha256:49214755b6153f90a597adcbff0252cc61069f8ab69ce8411285cd4a560e8038'

# pulled once before the cases, so a cold image cache never writes its progress into a case's
# compared output, and no case pays for the pull
setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
  docker pull -q "$blackbox_image" > /dev/null
  docker pull -q "$prometheus_image" > /dev/null
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/wait-for.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
  run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  # nixie's report bodies as Response.json writes them: the status, each readiness part, each
  # dependency part, and each advisory part (zgeoff/nixie modules/ops/src/build-health-app.ts)
  parts='"parts":{"database":{"isReady":true,"reason":null},"definitions":{"isReady":true,"reason":null}}'
  dependencies='"dependencies":{"imp_host":{"isReady":true,"reason":null},"conversation_imp":{"isReady":true,"reason":null}}'
  slow_dependencies='"dependencies":{"imp_host":{"isReady":false,"reason":"the check took longer than 2000 ms"},"conversation_imp":{"isReady":true,"reason":null}}'
  clear_body='{"status":"ready",'"$parts,$dependencies"',"advisory":{"conversation_turns":{"isReady":true,"reason":null}}}'
  failing_body='{"status":"ready",'"$parts,$dependencies"',"advisory":{"conversation_turns":{"isReady":false,"reason":"the last 3 turns failed"}}}'
  partless_body='{"status":"ready",'"$parts,$dependencies"'}'
  degraded_body='{"status":"degraded",'"$parts,$slow_dependencies"',"advisory":{"conversation_turns":{"isReady":true,"reason":null}}}'
}

# setup_test <tree>: the exporter's config and the rules, as JSON from the repo's builders, a file
# server over the case tree, and the exporter on the host network, both on loopback ports
setup_test() {
  local tree="$1"
  mkdir -p "$tree/www/health" "$tree/config"
  web_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  exporter_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  url="http://127.0.0.1:$web_port/health/ready"
  (cd "$repo" && TREE="$tree" URL="$url" bun -e "
    import { buildNixieProbeValues } from './infra/observability/build-nixie-probe-values.ts';
    import { buildAlertRules } from './infra/observability/build-alert-rules.ts';
    const tree = process.env.TREE ?? '';
    const url = process.env.URL ?? '';
    await Bun.write(tree + '/config/blackbox.json', JSON.stringify(buildNixieProbeValues(url).config));
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: buildAlertRules({ nixieReadinessURL: url }) }));
  ")
  # 3>&-, so the server does not keep bats' output pipe open past the case
  python3 -m http.server --bind 127.0.0.1 --directory "$tree/www" "$web_port" > "$tree/www.log" 2>&1 3>&- &
  server_pid=$!
  container="nixie-alerts-exporter-$run_id-$BASHPID"
  docker run -d --name "$container" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges -v "$tree/config:/config:ro" "$blackbox_image" \
    --config.file=/config/blackbox.json --web.listen-address="127.0.0.1:$exporter_port" > /dev/null
  wait_for 60 "the blackbox exporter" curl -fs -o /dev/null "http://127.0.0.1:$exporter_port/-/healthy"
  wait_for 10 "the file server" curl -fs -o /dev/null "http://127.0.0.1:$web_port/"
}

# each step safe when setup_test stopped before it
teardown() {
  stop_timeout_watchdog
  if [ -n "${container:-}" ]; then docker rm -f "$container" > /dev/null 2>&1 || true; fi
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2> /dev/null || true; fi
}

# read_probe_success <tree> <module> <body>: serves the body as nixie's report and prints the
# exporter's probe_success for it under the module
read_probe_success() {
  printf '%s' "$3" > "$1/www/health/ready"
  curl -fsS "http://127.0.0.1:$exporter_port/probe?module=$2&target=$url" > "$1/probe.txt"
  sed -n 's/^probe_success \([01]\)$/\1/p' "$1/probe.txt"
}

# run_rule_test <tree> <target> <alert> <probe_success> <expected alerts as JSON>: promtool's unit
# test of the rules, with the target's series held at the measured value for 20 minutes, read at 16
# minutes, past NixieTurnsFailing's 5 minute hold and NixieDegraded's 15 minute one
run_rule_test() {
  printf '%s' '{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"30s",
"input_series":[{"series":"probe_success{target=\"'"$2"'\"}","values":"'"$4"'x40"}],
"alert_rule_test":[{"eval_time":"16m","alertname":"'"$3"'","exp_alerts":'"$5"'}]}]}' \
    > "$1/config/test.json"
  docker run --rm --user 65532 --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp -v "$1/config:/config:ro" -w /config --entrypoint promtool "$prometheus_image" test rules test.json
}

@test "it fires NixieTurnsFailing on a body whose conversation turns fail" {
  setup_test "$tree"

  run -0 read_probe_success "$tree" nixie_turns "$failing_body"
  success="$output"
  run -0 run_rule_test "$tree" nixie-turns NixieTurnsFailing "$success" '[{"exp_labels":{"severity":"critical","target":"nixie-turns"},
"exp_annotations":{"summary":"nixie'"'"'s turns keep failing, or '"$url"' does not report them passing."}}]'

  assert_equal "$success" 0
  assert_output '  SUCCESS'
}

@test "it fires NixieTurnsFailing on a body without the conversation turns part" {
  setup_test "$tree"

  run -0 read_probe_success "$tree" nixie_turns "$partless_body"
  success="$output"
  run -0 run_rule_test "$tree" nixie-turns NixieTurnsFailing "$success" '[{"exp_labels":{"severity":"critical","target":"nixie-turns"},
"exp_annotations":{"summary":"nixie'"'"'s turns keep failing, or '"$url"' does not report them passing."}}]'

  assert_equal "$success" 0
  assert_output '  SUCCESS'
}

@test "it keeps NixieTurnsFailing quiet on a body whose conversation turns are clear" {
  setup_test "$tree"

  run -0 read_probe_success "$tree" nixie_turns "$clear_body"
  success="$output"
  run -0 run_rule_test "$tree" nixie-turns NixieTurnsFailing "$success" '[]'

  assert_equal "$success" 1
  assert_output '  SUCCESS'
}

@test "it fires NixieDegraded on a degraded body" {
  setup_test "$tree"

  run -0 read_probe_success "$tree" nixie_status "$degraded_body"
  success="$output"
  run -0 run_rule_test "$tree" nixie-status NixieDegraded "$success" '[{"exp_labels":{"severity":"warning","target":"nixie-status"},
"exp_annotations":{"summary":"nixie at '"$url"' reports degraded or unready, or does not answer; its body names the part."}}]'

  assert_equal "$success" 0
  assert_output '  SUCCESS'
}

@test "it keeps NixieDegraded quiet on a ready body whose conversation turns fail" {
  setup_test "$tree"

  run -0 read_probe_success "$tree" nixie_status "$failing_body"
  success="$output"
  run -0 run_rule_test "$tree" nixie-status NixieDegraded "$success" '[]'

  assert_equal "$success" 1
  assert_output '  SUCCESS'
}
