#!/usr/bin/env bash
# Journey for the atc sign-in alerts, end to end in the real engines: a gateway container log in
# the case tree, written in the kubelet's CRI format and stamped at now; the pinned Alloy running
# the pipeline build-atc-security-pipeline.ts builds; the pinned Prometheus scraping Alloy and
# evaluating the rules build-atc-sign-in-rules.ts builds; the pinned Alertmanager with the route
# build-alertmanager-values.ts builds; and the Discord webhook stand-in. The chart's InfoInhibitor
# rule and default inhibit rules run beside the built ones, as in the cluster. The first case fills
# the log with canary secrets, fails the first posts and then takes them, and checks that each
# category arrives as one Discord message, and that no canary reaches a Discord post, a retry, an
# alert, Alertmanager's log, or Alloy's metrics. The second checks that the owner's activity alone
# still reaches Discord. infra/observability/test-atc-sign-in-alerts.sh tests each stage on its own.
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
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/pick-port.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/has-metric.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-alloy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-alertmanager.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-stub-discord-webhook.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prometheus_image='quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e'
log_dir='logs/atc_atc-gateway-5d8f9c7b4-x2k9q_0f4e/atc-gateway'

# setup_test <tree>: the configs as the repo's builders write them beside the chart's inhibition,
# the Discord stand-in, and Alloy, Alertmanager and Prometheus on loopback ports, Prometheus
# scraping Alloy and evaluating each second
setup_test() {
  local tree="$1" port
  mkdir -p "$tree/config" "$tree/$log_dir" "$tree/discord" "$tree/alloy" "$tree/alertmanager"
  : > "$tree/$log_dir/0.log"
  start_stub_discord_webhook "$tree/discord"
  printf 'http://127.0.0.1:%s/api/webhooks/1234/CANARY-WEBHOOK-TOKEN' "$(cat "$tree/discord/port")" > "$tree/config/webhook-url"
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildATCSecurityPipeline } from './infra/observability/build-atc-security-pipeline.ts';
    import { buildATCSignInRules } from './infra/observability/build-atc-sign-in-rules.ts';
    import { buildAlertmanagerValues } from './infra/observability/build-alertmanager-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/config.alloy', buildATCSecurityPipeline('/logs/atc_atc-gateway-*/atc-gateway/*.log'));
    // the chart's InfoInhibitor rule and default inhibit rules beside the built ones, as Helm merges
    // them in the cluster (kube-prometheus-stack 91.8.2: general.rules.yaml, and values.yaml's
    // alertmanager.config.inhibit_rules)
    const infoInhibitor = {
      alert: 'InfoInhibitor',
      expr: 'group by (namespace) (ALERTS{severity = \"info\"} == 1) unless on (namespace) group by (namespace) (ALERTS{alertname != \"InfoInhibitor\", alertstate = \"firing\", severity =~ \"warning|critical\"} == 1)',
      labels: { severity: 'none' },
    };
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: [buildATCSignInRules(), { name: 'general.rules', rules: [infoInhibitor] }] }));
    const alertmanager = buildAlertmanagerValues({ secretName: 'alertmanager-discord', file: '/config/webhook-url' });
    await Bun.write(tree + '/config/alertmanager.json', JSON.stringify({
      ...alertmanager.config,
      inhibit_rules: [
        { source_matchers: ['severity = critical'], target_matchers: ['severity =~ warning|info'], equal: ['namespace', 'alertname'] },
        { source_matchers: ['severity = warning'], target_matchers: ['severity = info'], equal: ['namespace', 'alertname'] },
        { source_matchers: ['alertname = InfoInhibitor'], target_matchers: ['severity = info'], equal: ['namespace'] },
        { target_matchers: ['alertname = InfoInhibitor'] },
      ],
    }));
  ")
  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"
  start_alertmanager "$tree/alertmanager" "$tree/config"
  jq -n --arg alloy "$(sed 's|^http://||' "$tree/alloy/url")" --arg alertmanager "$(sed 's|^http://||' "$tree/alertmanager/url")" '{
    global: { scrape_interval: "1s", evaluation_interval: "1s" },
    rule_files: ["rules.json"],
    scrape_configs: [{ job_name: "alloy", static_configs: [{ targets: [$alloy] }] }],
    alerting: { alertmanagers: [{ static_configs: [{ targets: [$alertmanager] }] }] }
  }' > "$tree/config/prometheus.json"
  port="$(pick_port)"
  prometheus_url="http://127.0.0.1:$port"
  prometheus="atc-sign-in-journey-prometheus-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  # pulled here, so a cold image cache never writes its progress into a case's compared output
  docker pull -q "$prometheus_image" > /dev/null
  docker run -d --name "$prometheus" --network host --user 65532 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp -v "$tree/config:/config:ro" "$prometheus_image" \
    --config.file=/config/prometheus.json --storage.tsdb.path=/tmp/prometheus \
    --web.listen-address="127.0.0.1:$port" > /dev/null
  wait_for 60 "Alloy to tail the gateway's log" has_metric "$(cat "$tree/alloy/url")" '^loki_source_file_files_active_total{.*} 1$'
  wait_for 60 "Prometheus" curl -fs -o /dev/null "$prometheus_url/-/ready"
}

# teardown: each step safe when setup_test stopped before it
teardown() {
  if [ -n "${prometheus:-}" ]; then docker rm -f "$prometheus" > /dev/null 2>&1 || true; fi
  docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true
  docker rm -f "$(cat "$tree/alloy/container" 2> /dev/null)" > /dev/null 2>&1 || true
  kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true
  rm -rf "$tree" || true
}

# the condition a case waits on: Alertmanager's Discord posts that succeeded number at least $2,
# from its metrics at $1
# shellcheck disable=SC2016 # the bash -c that runs the condition expands it
delivered='curl -fsS "$1/metrics" 2> /dev/null | awk -v want="$2" '"'"'
  /^alertmanager_notification_requests_total\{integration="discord"/ { sent = $2 }
  /^alertmanager_notification_requests_failed_total\{integration="discord"/ { failed = $2 }
  END { exit !(sent - failed >= want) }'"'"

it_journeys_from_the_gateways_log_to_one_discord_message_per_category_with_no_canary_anywhere() {
  local now
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  echo 500 > "$tree/discord/status"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"

  {
    sed "s/@NOW@/$now/" << 'EOF'
@NOW@ stdout F Approve Notes app with code CANARY-APPROVAL-CODE
@NOW@ stderr F atc security {"v":1,"kind":"authorize_started","outcome":"accepted","route":"/oauth2/authorize","client":{"id":"CANARY-CLIENT-ID","name":"CANARY-CLIENT-NAME"},"redirectHost":"canary-redirect.example","correlationID":"CANARY-CORRELATION","peer":{"address":"10.42.0.17","provenance":"socket"},"forwarded":{"address":"203.0.113.77","header":"cf-connecting-ip","provenance":"trusted"},"userAgent":{"summary":"CANARY-USER-AGENT","provenance":"client"},"code":"CANARY-AUTH-CODE","state":"CANARY-STATE","code_challenge":"CANARY-PKCE"}
@NOW@ stderr F atc security {"v":1,"kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login","correlationID":"CANARY-CORRELATION","cookie":"session=CANARY-COOKIE","access_token":"CANARY-ACCESS-TOKEN","refresh_token":"CANARY-REFRESH-TOKEN","authorization":"Bearer CANARY-BEARER"}
EOF
    for _ in $(seq 30); do
      sed "s/@NOW@/$now/" << 'EOF'
@NOW@ stderr F atc security {"v":1,"kind":"authorize_invalid","outcome":"rejected","reason":"bad_host","route":"/oauth2/authorize?code=CANARY-QUERY-SECRET","userAgent":{"summary":"CANARY-USER-AGENT","provenance":"client"}}
EOF
    done
  } >> "$tree/$log_dir/0.log"
  wait_for 120 "Alertmanager to try Discord twice" test -f "$tree/discord/bodies/2.json"
  rm "$tree/discord/status"
  wait_for 300 "Alertmanager to deliver the three categories" bash -c "$delivered" _ "$(cat "$tree/alertmanager/url")" 3

  jq -r '.embeds[].title' "$tree"/discord/bodies/*.json | LC_ALL=C sort -u > "$tree/out"
  diff - "$tree/out" << 'EOF'
[FIRING:1] ATCGatewayInvalidSignInRequests (bad_host other warning)
[FIRING:1] ATCGatewayOwnerSignedIn (passkey /login notice)
[FIRING:1] ATCGatewaySignInStarted (/oauth2/authorize notice)
EOF
  jq -r '.embeds[].description' "$tree"/discord/bodies/*.json | grep -- '- summary = ' | LC_ALL=C sort -u > "$tree/out"
  diff - "$tree/out" << 'EOF'
 - summary = The atc gateway accepted 1 sign-in start(s) in the last 5m.
 - summary = The atc gateway rejected 30 invalid request(s), bad_host on other, in the last 5m.
 - summary = The owner signed in to the atc gateway 1 time(s) by passkey in the last 5m.
EOF
  cat "$tree"/discord/bodies/*.json > "$tree/posts"
  curl -fsS "$prometheus_url/api/v1/alerts" > "$tree/alerts"
  curl -fsS "$(cat "$tree/alertmanager/url")/api/v2/alerts" >> "$tree/alerts"
  docker logs "$(cat "$tree/alertmanager/container")" > "$tree/alertmanager.log" 2>&1
  curl -fsS "$(cat "$tree/alloy/url")/metrics" > "$tree/metrics"
  grep -Eio 'canary[a-z0-9-]*|203\.0\.113\.77|10\.42\.0\.17|/api/webhooks[^ "]*' \
    "$tree/posts" "$tree/alerts" "$tree/alertmanager.log" "$tree/metrics" > "$tree/leaks" || true
  diff /dev/null "$tree/leaks"
}

it_delivers_an_owners_sign_in_with_no_other_alert_firing_past_the_charts_info_inhibitor() {
  local now
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"

  sed "s/@NOW@/$now/" >> "$tree/$log_dir/0.log" << 'EOF'
@NOW@ stderr F atc security {"v":1,"kind":"authorize_started","outcome":"accepted","route":"/oauth2/authorize"}
@NOW@ stderr F atc security {"v":1,"kind":"owner_auth","outcome":"succeeded","method":"passkey","route":"/login"}
@NOW@ stderr F atc security {"v":1,"kind":"consent","outcome":"allowed","route":"/consent"}
EOF
  wait_for 180 "Alertmanager to deliver the three categories" bash -c "$delivered" _ "$(cat "$tree/alertmanager/url")" 3

  jq -r '.embeds[].title' "$tree"/discord/bodies/*.json | LC_ALL=C sort -u > "$tree/out"
  diff - "$tree/out" << 'EOF'
[FIRING:1] ATCGatewayConsentAllowed (notice)
[FIRING:1] ATCGatewayOwnerSignedIn (passkey /login notice)
[FIRING:1] ATCGatewaySignInStarted (/oauth2/authorize notice)
EOF
}

run_cases
