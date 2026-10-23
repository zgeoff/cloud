#!/usr/bin/env bash
# Test for the route and receivers build-alertmanager-values.ts builds, in the pinned Alertmanager:
# each case posts alerts to its API, with the mention template render-mention-template.ts renders
# for an invented user beside the config, and compares what Alertmanager posts to the Discord
# webhook stand-in.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='mention' bash infra/observability/test-alertmanager-routes.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/start-alertmanager.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/start-stub-discord-webhook.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# setup_test <tree>: the config and the mention template as the repo's builders write them, the
# Discord stand-in, and Alertmanager on a loopback port
setup_test() {
  local tree="$1"
  mkdir -p "$tree/config" "$tree/alertmanager" "$tree/discord"
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildAlertmanagerValues } from './infra/observability/build-alertmanager-values.ts';
    import { renderMentionTemplate } from './infra/observability/render-mention-template.ts';
    const tree = process.env.TREE ?? '';
    const alertmanager = buildAlertmanagerValues({ secretName: 'alertmanager-discord', file: '/config/webhook-url', mentionTemplateFile: '/config/mention.tmpl' });
    await Bun.write(tree + '/config/alertmanager.json', JSON.stringify(alertmanager.config));
    await Bun.write(tree + '/config/mention.tmpl', renderMentionTemplate('100000000000000001'));
  ")
  start_stub_discord_webhook "$tree/discord"
  printf 'http://127.0.0.1:%s/api/webhooks/1234/example-token' "$(cat "$tree/discord/port")" > "$tree/config/webhook-url"
  start_alertmanager "$tree/alertmanager" "$tree/config"
}

# teardown: each step safe when setup_test or the case stopped before it
teardown() {
  docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true
  kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true
  rm -rf "$tree" || true
}

it_posts_a_critical_alert_to_discord_twice_once_with_a_mention_of_the_user_and_a_warning_once_with_no_mention() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"

  curl -fsS -o /dev/null -H 'Content-Type: application/json' --data @- "$(cat "$tree/alertmanager/url")/api/v2/alerts" << 'EOF'
[{"labels":{"alertname":"ImpHostDown","severity":"critical","namespace":"imp"},"annotations":{"summary":"imp-host has not answered for 5m."}},
{"labels":{"alertname":"NixieDegraded","severity":"warning","namespace":"nixie"},"annotations":{"summary":"nixie reports a slow dependency."}}]
EOF
  wait_for 90 "Alertmanager to post the three messages" test -f "$tree/discord/bodies/3.json"

  jq -c '{ content, title: .embeds[0].title }' "$tree"/discord/bodies/*.json | LC_ALL=C sort > "$tree/out"
  diff - "$tree/out" << 'EOF'
{"content":"","title":"[FIRING:1] ImpHostDown in imp"}
{"content":"","title":"[FIRING:1] NixieDegraded in nixie"}
{"content":"<@100000000000000001>","title":"[FIRING:1] ImpHostDown in imp"}
EOF
  assert_missing "$tree/discord/unexpected" "the Discord stand-in's unexpected requests"
}

it_cuts_the_title_of_an_alert_with_a_long_name_and_namespace_within_discords_256_runes() {
  local name namespace
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  name="$(printf 'é%.0s' $(seq 300))"
  namespace="$(printf 'n%.0s' $(seq 100))"

  jq -n --arg name "$name" --arg namespace "$namespace" '[{
    labels: { alertname: $name, severity: "warning", namespace: $namespace, pod: ("p" * 200), container: ("c" * 200) },
    annotations: { summary: "A long alert." }
  }]' | curl -fsS -o /dev/null -H 'Content-Type: application/json' --data @- "$(cat "$tree/alertmanager/url")/api/v2/alerts"
  wait_for 90 "Alertmanager to post the message" test -f "$tree/discord/bodies/1.json"

  jq -r '.embeds[0].title' "$tree/discord/bodies/1.json" > "$tree/out"
  printf '[FIRING:1] %s in %s\n' "${name:0:150}" "${namespace:0:63}" | diff - "$tree/out"
  jq '.embeds[0].title | length' "$tree/discord/bodies/1.json" > "$tree/runes"
  assert_equals 228 "$(cat "$tree/runes")" "the title's runes"
  docker logs "$(cat "$tree/alertmanager/container")" > "$tree/log" 2>&1
  grep 'Truncated' "$tree/log" > "$tree/truncated" || true
  diff /dev/null "$tree/truncated"
}

run_cases
