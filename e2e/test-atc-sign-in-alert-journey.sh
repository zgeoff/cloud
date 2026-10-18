#!/usr/bin/env bash
# Journey for the atc sign-in alerts, end to end in the real engines: a gateway container log in
# the case tree, written in the kubelet's CRI format and full of canary secrets; the pinned Alloy
# running the pipeline build-atc-security-pipeline.ts builds; the pinned Prometheus scraping Alloy
# and evaluating the rules build-atc-sign-in-rules.ts builds; the pinned Alertmanager with the route
# build-alertmanager-values.ts builds; and the Discord webhook stand-in, which fails the first posts
# and then takes them. The journey checks that each category arrives as one Discord message, and
# that no canary reaches a Discord post, a retry, an alert, Alertmanager's log, or Alloy's metrics.
# infra/observability/test-atc-sign-in-alerts.sh tests each stage on its own.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='journey' bash e2e/test-atc-sign-in-alert-journey.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-stub-discord-webhook.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
alloy_image='grafana/alloy:v1.20.0@sha256:f111cce835516c5f99166342be7038496b52ced16667be5a11e19258a3e4cd30'
alertmanager_image='quay.io/prometheus/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a'
prometheus_image='quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e'
run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
log_dir='logs/atc_atc-gateway-5d8f9c7b4-x2k9q_0f4e/atc-gateway'

# setup_test <tree>: the configs as the repo's builders write them, the Discord stand-in failing
# every post, and Alloy, Alertmanager and Prometheus on loopback ports, Prometheus scraping Alloy
# and evaluating each second
setup_test() {
  local tree="$1" alloy_port alertmanager_port
  mkdir -p "$tree/config" "$tree/$log_dir" "$tree/discord"
  : > "$tree/$log_dir/0.log"
  alloy_port="$(pick_port)"
  alertmanager_port="$(pick_port)"
  prometheus_port="$(pick_port)"
  alloy_url="http://127.0.0.1:$alloy_port"
  alertmanager_url="http://127.0.0.1:$alertmanager_port"
  echo 500 > "$tree/discord/status"
  start_stub_discord_webhook "$tree/discord"
  printf 'http://127.0.0.1:%s/api/webhooks/1234/CANARY-WEBHOOK-TOKEN' "$(cat "$tree/discord/port")" > "$tree/config/webhook-url"
  (cd "$repo" && TREE="$tree" ALLOY="127.0.0.1:$alloy_port" ALERTMANAGER="127.0.0.1:$alertmanager_port" bun -e "
    import { buildATCSecurityPipeline } from './infra/observability/build-atc-security-pipeline.ts';
    import { buildATCSignInRules } from './infra/observability/build-atc-sign-in-rules.ts';
    import { buildAlertmanagerValues } from './infra/observability/build-alertmanager-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/config.alloy', buildATCSecurityPipeline('/logs/atc_atc-gateway-*/atc-gateway/*.log'));
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: [buildATCSignInRules()] }));
    const alertmanager = buildAlertmanagerValues({ secretName: 'alertmanager-discord', file: '/config/webhook-url' });
    await Bun.write(tree + '/config/alertmanager.json', JSON.stringify(alertmanager.config));
    await Bun.write(tree + '/config/prometheus.json', JSON.stringify({
      global: { scrape_interval: '1s', evaluation_interval: '1s' },
      rule_files: ['rules.json'],
      scrape_configs: [{ job_name: 'alloy', static_configs: [{ targets: [process.env.ALLOY] }] }],
      alerting: { alertmanagers: [{ static_configs: [{ targets: [process.env.ALERTMANAGER] }] }] },
    }));
  ")
  # pulled here, so a cold image cache never writes its progress into a case's compared output
  docker pull -q "$alloy_image" > /dev/null
  docker pull -q "$alertmanager_image" > /dev/null
  docker pull -q "$prometheus_image" > /dev/null
  alloy="atc-sign-in-journey-alloy-$run_id-$BASHPID"
  docker run -d --name "$alloy" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$tree/config:/config:ro" -v "$tree/logs:/logs:ro" \
    "$alloy_image" run --disable-reporting --server.http.listen-addr="127.0.0.1:$alloy_port" \
    --storage.path=/tmp/alloy /config/config.alloy > /dev/null
  alertmanager="atc-sign-in-journey-alertmanager-$run_id-$BASHPID"
  docker run -d --name "$alertmanager" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$tree/config:/config:ro" "$alertmanager_image" \
    --config.file=/config/alertmanager.json --storage.path=/tmp/alertmanager \
    --web.listen-address="127.0.0.1:$alertmanager_port" --cluster.listen-address= > /dev/null
  prometheus="atc-sign-in-journey-prometheus-$run_id-$BASHPID"
  docker run -d --name "$prometheus" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$tree/config:/config:ro" "$prometheus_image" \
    --config.file=/config/prometheus.json --storage.tsdb.path=/tmp/prometheus \
    --web.listen-address="127.0.0.1:$prometheus_port" > /dev/null
  wait_for 60 "Alloy to tail the gateway's log" has_metric "$alloy_url" '^loki_source_file_files_active_total{.*} 1$'
  wait_for 60 "Alertmanager" curl -fs -o /dev/null "$alertmanager_url/-/ready"
  wait_for 60 "Prometheus" curl -fs -o /dev/null "http://127.0.0.1:$prometheus_port/-/ready"
}

# teardown: each step safe when setup_test stopped before it
teardown() {
  local container
  for container in "${prometheus:-}" "${alertmanager:-}" "${alloy:-}"; do
    if [ -n "$container" ]; then docker rm -f "$container" > /dev/null 2>&1 || true; fi
  done
  if [ -f "$tree/discord/pid" ]; then kill "$(cat "$tree/discord/pid")" 2> /dev/null || true; fi
  rm -rf "$tree" || true
}

# pick_port: a free loopback port
pick_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# has_metric <url> <pattern>: whether a line of the metrics at <url> matches the pattern
has_metric() {
  curl -fsS "$1/metrics" 2> /dev/null | grep -q -- "$2"
}

# has_delivered <count>: whether Alertmanager's Discord posts that succeeded number at least <count>
has_delivered() {
  curl -fsS "$alertmanager_url/metrics" 2> /dev/null | awk -v want="$1" '
    /^alertmanager_notification_requests_total\{integration="discord"/ { sent = $2 }
    /^alertmanager_notification_requests_failed_total\{integration="discord"/ { failed = $2 }
    END { exit !(sent - failed >= want) }'
}

it_journeys_from_the_gateways_log_to_one_discord_message_per_category_with_no_canary_anywhere() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  {
    printf '%s\n' '2026-10-19T09:01:00.000000000Z stdout F Approve Notes app with code CANARY-APPROVAL-CODE'
    printf '%s\n' '2026-10-19T09:01:01.000000000Z stderr F atc security {"v":1,"kind":"authorize_started","outcome":"accepted","route":"/oauth2/authorize","client":{"id":"CANARY-CLIENT-ID","name":"CANARY-CLIENT-NAME"},"redirectHost":"canary-redirect.example","correlationID":"CANARY-CORRELATION","peer":{"address":"10.42.0.17","provenance":"socket"},"forwarded":{"address":"203.0.113.77","header":"cf-connecting-ip","provenance":"trusted"},"userAgent":{"summary":"CANARY-USER-AGENT","provenance":"client"},"code":"CANARY-AUTH-CODE","state":"CANARY-STATE","code_challenge":"CANARY-PKCE"}'
    printf '%s\n' '2026-10-19T09:01:02.000000000Z stderr F atc security {"v":1,"kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login","correlationID":"CANARY-CORRELATION","cookie":"session=CANARY-COOKIE","access_token":"CANARY-ACCESS-TOKEN","refresh_token":"CANARY-REFRESH-TOKEN","authorization":"Bearer CANARY-BEARER"}'
    for _ in $(seq 30); do
      printf '%s\n' '2026-10-19T09:01:03.000000000Z stderr F atc security {"v":1,"kind":"authorize_invalid","outcome":"rejected","reason":"bad_host","route":"/oauth2/authorize?code=CANARY-QUERY-SECRET","userAgent":{"summary":"CANARY-USER-AGENT","provenance":"client"}}'
    done
  } >> "$tree/$log_dir/0.log"
  wait_for 120 "Alertmanager to try Discord twice" test -f "$tree/discord/bodies/2.json"
  rm "$tree/discord/status"
  wait_for 300 "Alertmanager to deliver the three categories" has_delivered 3

  jq -r '.embeds[].title' "$tree"/discord/bodies/*.json | LC_ALL=C sort -u > "$tree/out"
  diff - "$tree/out" << 'EOF'
[FIRING:1] ATCGatewayInvalidSignInRequests (bad_host other warning)
[FIRING:1] ATCGatewayOwnerSignedIn (passkey /login info)
[FIRING:1] ATCGatewaySignInStarted (/oauth2/authorize info)
EOF
  jq -r '.embeds[].description' "$tree"/discord/bodies/*.json | grep -- '- summary = ' | LC_ALL=C sort -u > "$tree/out"
  diff - "$tree/out" << 'EOF'
 - summary = The atc gateway accepted 1 sign-in start(s) in the last 5m.
 - summary = The atc gateway rejected 30 invalid request(s), bad_host on other, in the last 5m.
 - summary = The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m.
EOF
  cat "$tree"/discord/bodies/*.json > "$tree/posts"
  curl -fsS "http://127.0.0.1:$prometheus_port/api/v1/alerts" > "$tree/alerts"
  curl -fsS "$alertmanager_url/api/v2/alerts" >> "$tree/alerts"
  docker logs "$alertmanager" > "$tree/alertmanager.log" 2>&1
  curl -fsS "$alloy_url/metrics" > "$tree/metrics"
  grep -Eio 'canary[a-z0-9-]*|203\.0\.113\.77|10\.42\.0\.17|/api/webhooks[^ "]*' \
    "$tree/posts" "$tree/alerts" "$tree/alertmanager.log" "$tree/metrics" > "$tree/leaks" || true
  diff /dev/null "$tree/leaks"
}

run_cases
