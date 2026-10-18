#!/usr/bin/env bash
# Test for the atc sign-in alerts in their real engines, one stage per case. The pinned Alloy runs
# the pipeline build-atc-security-pipeline.ts builds over a gateway container log in the case tree,
# written in the kubelet's CRI format, and each Alloy case compares the security counters it
# exports. promtool tests the rules build-atc-sign-in-rules.ts builds against series shaped like
# those counters. The pinned Alertmanager runs the route and receivers build-alertmanager-values.ts
# builds and posts to the Discord webhook stand-in. Each image is the version its chart runs: Alloy
# the alloy chart's appVersion, and Alertmanager and Prometheus kube-prometheus-stack's image tags.
# e2e/test-atc-sign-in-alert-journey.sh runs the stages together.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='burst' bash infra/observability/test-atc-sign-in-alerts.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/start-stub-discord-webhook.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
alloy_image='grafana/alloy:v1.20.0@sha256:f111cce835516c5f99166342be7038496b52ced16667be5a11e19258a3e4cd30'
alertmanager_image='quay.io/prometheus/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a'
prometheus_image='quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e'
run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"

# setup_test <tree>: the configs as the repo's builders write them, and the images pulled here, so a
# cold image cache never writes its progress into a case's compared output
setup_test() {
  local tree="$1"
  mkdir -p "$tree/config" "$tree/logs/atc_atc-gateway-5d8f9c7b4-x2k9q_0f4e/atc-gateway" "$tree/discord"
  : > "$tree/logs/atc_atc-gateway-5d8f9c7b4-x2k9q_0f4e/atc-gateway/0.log"
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildATCSecurityPipeline } from './infra/observability/build-atc-security-pipeline.ts';
    import { buildATCSignInRules } from './infra/observability/build-atc-sign-in-rules.ts';
    import { buildAlertmanagerValues } from './infra/observability/build-alertmanager-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/config.alloy', buildATCSecurityPipeline('/logs/atc_atc-gateway-*/atc-gateway/*.log'));
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: [buildATCSignInRules()] }));
    const alertmanager = buildAlertmanagerValues({ secretName: 'alertmanager-discord', file: '/config/webhook-url' });
    await Bun.write(tree + '/config/alertmanager.json', JSON.stringify(alertmanager.config));
  ")
  docker pull -q "$alloy_image" > /dev/null
  docker pull -q "$alertmanager_image" > /dev/null
  docker pull -q "$prometheus_image" > /dev/null
}

# teardown: each step safe when setup_test or the case stopped before it
teardown() {
  if [ -n "${alloy:-}" ]; then docker rm -f "$alloy" > /dev/null 2>&1 || true; fi
  if [ -n "${alertmanager:-}" ]; then docker rm -f "$alertmanager" > /dev/null 2>&1 || true; fi
  if [ -f "$tree/discord/pid" ]; then kill "$(cat "$tree/discord/pid")" 2> /dev/null || true; fi
  rm -rf "$tree" || true
}

# pick_port: a free loopback port
pick_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# start_alloy <tree>: Alloy on the case's log directory, once it tails the gateway's log
start_alloy() {
  alloy_port="$(pick_port)"
  alloy="atc-sign-in-alloy-$run_id-$BASHPID"
  docker run -d --name "$alloy" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$1/config:/config:ro" -v "$1/logs:/logs:ro" \
    "$alloy_image" run --disable-reporting --server.http.listen-addr="127.0.0.1:$alloy_port" \
    --storage.path=/tmp/alloy /config/config.alloy > /dev/null
  wait_for 60 "Alloy to tail the gateway's log" has_alloy_metric '^loki_source_file_files_active_total{.*} 1$'
}

# has_alloy_metric <pattern>: whether a line of Alloy's metrics matches the pattern
has_alloy_metric() {
  curl -fsS "http://127.0.0.1:$alloy_port/metrics" 2> /dev/null | grep -q -- "$1"
}

# write_log_lines <tree>: appends stdin's lines to the gateway's log, as the kubelet does
write_log_lines() {
  cat >> "$1/logs/atc_atc-gateway-5d8f9c7b4-x2k9q_0f4e/atc-gateway/0.log"
}

# read_security_metrics <tree>: writes Alloy's whole metrics page to <tree>/metrics, and prints its
# atc security counters
read_security_metrics() {
  curl -fsS "http://127.0.0.1:$alloy_port/metrics" > "$1/metrics"
  grep '^loki_process_custom_atc_security_' "$1/metrics"
}

# start_alertmanager <tree>: Alertmanager with the built route and receivers, posting to the
# Discord stand-in under a webhook URL whose token is the case's canary
start_alertmanager() {
  local port
  start_stub_discord_webhook "$1/discord"
  printf 'http://127.0.0.1:%s/api/webhooks/1234/CANARY-WEBHOOK-TOKEN' "$(cat "$1/discord/port")" > "$1/config/webhook-url"
  port="$(pick_port)"
  alertmanager_url="http://127.0.0.1:$port"
  alertmanager="atc-sign-in-alertmanager-$run_id-$BASHPID"
  docker run -d --name "$alertmanager" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$1/config:/config:ro" "$alertmanager_image" \
    --config.file=/config/alertmanager.json --storage.path=/tmp/alertmanager \
    --web.listen-address="127.0.0.1:$port" --cluster.listen-address= > /dev/null
  wait_for 60 "Alertmanager" curl -fs -o /dev/null "$alertmanager_url/-/ready"
}

# send_alerts: posts stdin's alerts to Alertmanager as Prometheus does
send_alerts() {
  curl -fsS -o /dev/null -H 'Content-Type: application/json' --data @- "$alertmanager_url/api/v2/alerts"
}

# run_rule_test <tree>: promtool's unit test of the sign-in rules, from stdin
run_rule_test() {
  cat > "$1/config/test.json"
  docker run --rm --user 65532 --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp -v "$1/config:/config:ro" -w /config --entrypoint promtool "$prometheus_image" test rules test.json
}

it_counts_each_sign_in_outcome_from_the_gateways_stderr_and_nothing_from_stdout_or_from_before_alloy_started() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  write_log_lines "$tree" << 'EOF'
2026-10-19T09:00:00.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:00:00.000Z","kind":"consent","outcome":"allowed","route":"/consent"}
EOF
  start_alloy "$tree"

  write_log_lines "$tree" << 'EOF'
2026-10-19T09:01:00.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:00.000Z","kind":"authorize_started","outcome":"accepted","route":"/oauth2/authorize","client":{"id":"client-7","name":"Notes app"},"redirectHost":"notes.example","correlationID":"c0ffee00c0ffee00"}
2026-10-19T09:01:01.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:01.000Z","kind":"authorize_started","outcome":"rejected","reason":"rate_limited","route":"/oauth2/authorize"}
2026-10-19T09:01:02.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:02.000Z","kind":"authorize_invalid","outcome":"rejected","reason":"invalid_redirect","route":"/oauth2/authorize"}
2026-10-19T09:01:03.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:03.000Z","kind":"authorize_invalid","outcome":"rejected","reason":"bad_host","route":"/mcp"}
2026-10-19T09:01:04.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:04.000Z","kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login","correlationID":"c0ffee00c0ffee00"}
2026-10-19T09:01:05.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:05.000Z","kind":"owner_auth","outcome":"failed","reason":"assertion_failed","method":"passkey","route":"/login"}
2026-10-19T09:01:06.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:06.000Z","kind":"owner_auth","outcome":"failed","reason":"invalid_token","method":"enrollment_token","route":"/enroll"}
2026-10-19T09:01:07.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:07.000Z","kind":"consent","outcome":"allowed","route":"/consent","correlationID":"c0ffee00c0ffee00"}
2026-10-19T09:01:08.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:08.000Z","kind":"suppressed","reason":"authorize_invalid","count":37}
2026-10-19T09:01:09.000000000Z stdout F atc security {"v":1,"ts":"2026-10-19T09:01:09.000Z","kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login"}
2026-10-19T09:01:10.000000000Z stdout F Approve Notes app with code 482913
2026-10-19T09:01:11.000000000Z stderr F listening on :8080
2026-10-19T09:01:12.000000000Z stderr F atc security {"v":1,"ts":"2026-10-19T09:01:12.000Z","kind":"consent","outcome":"denied","reason":"none_ticked","route":"/consent"}
EOF
  wait_for 30 "Alloy to count the last event" has_alloy_metric 'kind="consent",method="none",outcome="denied"'

  read_security_metrics "$tree" > "$tree/out"
  diff - "$tree/out" << 'EOF'
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="authorize_invalid",method="none",outcome="rejected",reason="bad_host",route="/mcp"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="authorize_invalid",method="none",outcome="rejected",reason="invalid_redirect",route="/oauth2/authorize"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="authorize_started",method="none",outcome="accepted",reason="none",route="/oauth2/authorize"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="authorize_started",method="none",outcome="rejected",reason="rate_limited",route="/oauth2/authorize"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="consent",method="none",outcome="allowed",reason="none",route="/consent"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="consent",method="none",outcome="denied",reason="none_ticked",route="/consent"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="enrollment_token",outcome="failed",reason="invalid_token",route="/enroll"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="passkey",outcome="failed",reason="assertion_failed",route="/login"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="passkey",outcome="succeeded",reason="none",route="/login"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="suppressed",method="none",outcome="none",reason="authorize_invalid",route="none"} 1
loki_process_custom_atc_security_suppressed_events_total{component_id="loki.process.atc_security",component_path="/",kind="suppressed",method="none",outcome="none",reason="authorize_invalid",route="none"} 37
EOF
}

it_counts_a_line_outside_the_contract_under_other_and_keeps_every_client_string_out_of_the_metrics() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  start_alloy "$tree"

  write_log_lines "$tree" << 'EOF'
2026-10-19T09:01:00.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login","client":{"id":"CANARY-CLIENT-ID","name":"CANARY-CLIENT-NAME"},"redirectHost":"canary-redirect.example","correlationID":"CANARY-CORRELATION","userAgent":{"summary":"CANARY-USER-AGENT","provenance":"client"},"code":"CANARY-AUTH-CODE","access_token":"CANARY-ACCESS-TOKEN","refresh_token":"CANARY-REFRESH-TOKEN","cookie":"session=CANARY-COOKIE","authorization":"Bearer CANARY-BEARER","state":"CANARY-STATE","code_verifier":"CANARY-PKCE","url":"/oauth2/authorize?code=CANARY-QUERY-SECRET"}
2026-10-19T09:01:01.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"failed","reason":"CANARY-REASON","method":"CANARY-METHOD","route":"/oauth2/authorize?code=CANARY-ROUTE-QUERY"}
2026-10-19T09:01:02.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"CANARY-OUTCOME","route":"/login"}
2026-10-19T09:01:03.000000000Z stderr F atc security {"v":1,"kind":"CANARY-KIND","outcome":"succeeded"}
2026-10-19T09:01:04.000000000Z stderr F atc security {"v":1,"kind":"suppressed","reason":"owner_auth","count":"CANARY-COUNT"}
2026-10-19T09:01:05.000000000Z stderr F atc security {CANARY-NOT-JSON
2026-10-19T09:01:06.000000000Z stdout F Approve Notes app with code CANARY-APPROVAL-CODE
2026-10-19T09:01:07.000000000Z stderr F atc security {"v":1,"kind":"consent","outcome":"denied","reason":"none_ticked","route":"/consent"}
EOF
  wait_for 30 "Alloy to count the last event" has_alloy_metric 'kind="consent",method="none",outcome="denied"'

  read_security_metrics "$tree" > "$tree/out"
  diff - "$tree/out" << 'EOF'
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="consent",method="none",outcome="denied",reason="none_ticked",route="/consent"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="other",method="none",outcome="other",reason="none",route="/login"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="other",method="none",outcome="other",reason="none",route="none"} 2
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="other",outcome="failed",reason="other",route="other"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="passkey",outcome="succeeded",reason="none",route="/login"} 1
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="suppressed",method="none",outcome="none",reason="owner_auth",route="none"} 1
loki_process_custom_atc_security_suppressed_events_total{component_id="loki.process.atc_security",component_path="/",kind="suppressed",method="none",outcome="none",reason="owner_auth",route="none"} 0
EOF
  grep -io 'canary[a-z0-9-]*' "$tree/metrics" > "$tree/leaks" || true
  diff /dev/null "$tree/leaks"
}

it_gives_a_forwarded_address_no_place_in_the_metrics_even_one_marked_trusted() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  start_alloy "$tree"

  write_log_lines "$tree" << 'EOF'
2026-10-19T09:01:00.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"failed","reason":"assertion_failed","method":"passkey","route":"/login","peer":{"address":"10.42.0.17","provenance":"socket"},"forwarded":{"address":"203.0.113.77","header":"cf-connecting-ip","provenance":"trusted"}}
2026-10-19T09:01:01.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"failed","reason":"assertion_failed","method":"passkey","route":"/login","peer":{"address":"10.42.0.17","provenance":"socket"},"forwarded":{"address":"198.51.100.4","header":"cf-connecting-ip","provenance":"unverified"}}
EOF
  wait_for 30 "Alloy to count both events" has_alloy_metric 'outcome="failed",reason="assertion_failed",route="/login"} 2$'

  read_security_metrics "$tree" > "$tree/out"
  diff - "$tree/out" << 'EOF'
loki_process_custom_atc_security_events_total{component_id="loki.process.atc_security",component_path="/",kind="owner_auth",method="passkey",outcome="failed",reason="assertion_failed",route="/login"} 2
EOF
  grep -Eo '203\.0\.113\.77|198\.51\.100\.4|10\.42\.0\.17|trusted|unverified|provenance|forwarded' "$tree/metrics" > "$tree/leaks" || true
  diff /dev/null "$tree/leaks"
}

it_sums_a_burst_of_invalid_requests_into_one_alert_per_reason_and_route_with_its_count() {
  local status=0
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  run_rule_test "$tree" > "$tree/out" 2>&1 << 'EOF' || status=$?
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"30s",
"input_series":[
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"authorize_invalid\",method=\"none\",outcome=\"rejected\",reason=\"bad_host\",route=\"/mcp\"}","values":"0 0 0 0 0 0 0 0 0 0 0 0 20 140 380 400 400 400 400 400 400"},
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"authorize_invalid\",method=\"none\",outcome=\"rejected\",reason=\"invalid_client\",route=\"/oauth2/authorize\"}","values":"0 0 0 0 0 0 0 0 0 0 0 0 0 100 100 100 100 100 100 100 100"}],
"alert_rule_test":[{"eval_time":"7m30s","alertname":"ATCGatewayInvalidSignInRequests","exp_alerts":[
{"exp_labels":{"severity":"warning","reason":"bad_host","route":"/mcp"},
"exp_annotations":{"summary":"The atc gateway rejected 400 invalid request(s), bad_host on /mcp, in the last 5m."}},
{"exp_labels":{"severity":"warning","reason":"invalid_client","route":"/oauth2/authorize"},
"exp_annotations":{"summary":"The atc gateway rejected 100 invalid request(s), invalid_client on /oauth2/authorize, in the last 5m."}}]}]}]}
EOF

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_keeps_an_accepted_start_and_a_successful_sign_in_in_separate_alerts() {
  local status=0
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  run_rule_test "$tree" > "$tree/out" 2>&1 << 'EOF' || status=$?
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"30s",
"input_series":[
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"authorize_started\",method=\"none\",outcome=\"accepted\",reason=\"none\",route=\"/oauth2/authorize\"}","values":"0 0 0 0 0 0 0 0 0 0 0 0 2 2 2 2 2 2 2 2 2"},
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"owner_auth\",method=\"passkey\",outcome=\"succeeded\",reason=\"none\",route=\"/login\"}","values":"0 0 0 0 0 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1"}],
"alert_rule_test":[
{"eval_time":"7m30s","alertname":"ATCGatewaySignInStarted","exp_alerts":[
{"exp_labels":{"severity":"notice","route":"/oauth2/authorize"},
"exp_annotations":{"summary":"The atc gateway accepted 2 sign-in start(s) in the last 5m."}}]},
{"eval_time":"7m30s","alertname":"ATCGatewayOwnerSignedIn","exp_alerts":[
{"exp_labels":{"severity":"notice","method":"passkey","route":"/login"},
"exp_annotations":{"summary":"The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m."}}]}]}]}
EOF

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_fires_on_the_first_event_of_a_new_series_or_after_alloy_restarts_and_clears_a_window_after_the_last() {
  local status=0
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  # the sign-in series appears at 1m holding its first event; the consent series drops from 7 to 1
  # when Alloy restarts at 9m, with one consent since
  run_rule_test "$tree" > "$tree/out" 2>&1 << 'EOF' || status=$?
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"30s",
"input_series":[
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"owner_auth\",method=\"passkey\",outcome=\"succeeded\",reason=\"none\",route=\"/login\"}","values":"_ _ 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"},
{"series":"loki_process_custom_atc_security_events_total{component_id=\"loki.process.atc_security\",component_path=\"/\",kind=\"consent\",method=\"none\",outcome=\"allowed\",reason=\"none\",route=\"/consent\"}","values":"7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 1 1 1"}],
"alert_rule_test":[
{"eval_time":"1m","alertname":"ATCGatewayOwnerSignedIn","exp_alerts":[
{"exp_labels":{"severity":"notice","method":"passkey","route":"/login"},
"exp_annotations":{"summary":"The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m."}}]},
{"eval_time":"6m30s","alertname":"ATCGatewayOwnerSignedIn","exp_alerts":[]},
{"eval_time":"8m","alertname":"ATCGatewayConsentAllowed","exp_alerts":[]},
{"eval_time":"9m30s","alertname":"ATCGatewayConsentAllowed","exp_alerts":[
{"exp_labels":{"severity":"notice"},
"exp_annotations":{"summary":"The owner allowed 1 client consent(s) at the atc gateway in the last 5m."}}]}]}]}
EOF

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_sends_one_discord_message_per_sign_in_alert_name_however_many_alerts_and_posts_arrive() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  start_alertmanager "$tree"

  for _ in 1 2 3 4 5; do
    send_alerts << 'EOF'
[{"labels":{"alertname":"ATCGatewayInvalidSignInRequests","severity":"warning","reason":"bad_host","route":"/mcp"},"annotations":{"summary":"The atc gateway rejected 400 invalid request(s), bad_host on /mcp, in the last 5m."}},
{"labels":{"alertname":"ATCGatewayInvalidSignInRequests","severity":"warning","reason":"invalid_client","route":"/oauth2/authorize"},"annotations":{"summary":"The atc gateway rejected 100 invalid request(s), invalid_client on /oauth2/authorize, in the last 5m."}},
{"labels":{"alertname":"ATCGatewaySignInStarted","severity":"notice","route":"/oauth2/authorize"},"annotations":{"summary":"The atc gateway accepted 1 sign-in start(s) in the last 5m."}},
{"labels":{"alertname":"ATCGatewayOwnerSignedIn","severity":"notice","method":"passkey","route":"/login"},"annotations":{"summary":"The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m."}}]
EOF
  done
  wait_for 90 "Alertmanager to post to Discord" test -f "$tree/discord/bodies/3.json"

  jq -r '.embeds[].title' "$tree"/discord/bodies/*.json | LC_ALL=C sort > "$tree/out"
  diff - "$tree/out" << 'EOF'
[FIRING:1] ATCGatewayOwnerSignedIn (passkey /login notice)
[FIRING:1] ATCGatewaySignInStarted (/oauth2/authorize notice)
[FIRING:2] ATCGatewayInvalidSignInRequests (warning)
EOF
  diff - "$tree/discord/requests" << 'EOF'
POST /api/webhooks/1234/CANARY-WEBHOOK-TOKEN
POST /api/webhooks/1234/CANARY-WEBHOOK-TOKEN
POST /api/webhooks/1234/CANARY-WEBHOOK-TOKEN
EOF
}

it_logs_and_counts_a_failed_discord_delivery_without_the_webhooks_token() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  echo 500 > "$tree/discord/status"
  start_alertmanager "$tree"

  send_alerts << 'EOF'
[{"labels":{"alertname":"ATCGatewayOwnerSignedIn","severity":"notice","method":"passkey","route":"/login"},"annotations":{"summary":"The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m."}}]
EOF
  wait_for 90 "Alertmanager to retry the post" test -f "$tree/discord/bodies/2.json"

  curl -fsS "$alertmanager_url/metrics" | grep '^alertmanager_notification_requests_failed_total{integration="discord"' > "$tree/failed"
  docker logs "$alertmanager" > "$tree/log" 2>&1

  # the retries go on while the case reads, so the count is a measurement: at least the two posts
  # the stand-in took, and masked in the compared line
  [ "$(awk '{ print $2 }' "$tree/failed")" -ge 2 ] || {
    echo "failed count $(cat "$tree/failed"), want 2 or more" >&2
    exit 1
  }
  sed 's/ [0-9]*$/ <count>/' "$tree/failed" > "$tree/out"
  diff - "$tree/out" << 'EOF'
alertmanager_notification_requests_failed_total{integration="discord"} <count>
EOF
  grep -c 'msg="Notify attempt failed, will retry later" component=dispatcher receiver=discord-sign-in integration=discord\[0\]' "$tree/log" > /dev/null
  grep -o 'CANARY[A-Z-]*\|/api/webhooks[^ "]*' "$tree/log" > "$tree/leaks" || true
  diff /dev/null "$tree/leaks"
}

run_cases
