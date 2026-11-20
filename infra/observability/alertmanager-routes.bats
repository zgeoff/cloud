#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for the route and receivers build-alertmanager-values.ts builds, in the pinned Alertmanager:
# each case posts alerts to its API, with the mention template render-mention-template.ts renders
# for an invented user beside the config, and compares what Alertmanager posts to the Discord
# webhook stand-in. Alertmanager holds a new group for 1 s in place of production's 30 s, which the
# builder's own test pins.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='mention' bash scripts/run-bats.sh alert-rules

# Alertmanager posts after its group wait and the first case pulls its image on a cold cache
export BATS_TEST_TIMEOUT=240

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/wait-for.sh'
  load '../../scripts/src/test-utils/shell/start-alertmanager.sh'
  load '../../scripts/src/test-utils/shell/start-stub-discord-webhook.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
}

# setup_test <tree>: the config and the mention template as the repo's builders write them, the
# Discord stand-in, and Alertmanager on a loopback port
setup_test() {
  local tree="$1"
  mkdir -p "$tree/config" "$tree/alertmanager" "$tree/discord"
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildAlertmanagerValues } from './infra/observability/build-alertmanager-values.ts';
    import { renderMentionTemplate } from './infra/observability/render-mention-template.ts';
    const tree = process.env.TREE ?? '';
    const alertmanager = buildAlertmanagerValues({ secretName: 'alertmanager-discord', file: '/config/webhook-url', mentionTemplateFile: '/config/mention.tmpl' }, { groupWait: '1s' });
    await Bun.write(tree + '/config/alertmanager.json', JSON.stringify(alertmanager.config));
    await Bun.write(tree + '/config/mention.tmpl', renderMentionTemplate('100000000000000001'));
  ")
  start_stub_discord_webhook "$tree/discord"
  printf 'http://127.0.0.1:%s/api/webhooks/1234/example-token' "$(cat "$tree/discord/port")" > "$tree/config/webhook-url"
  start_alertmanager "$tree/alertmanager" "$tree/config"
}

# each step safe when setup_test or the case stopped before it
teardown() {
  stop_timeout_watchdog
  docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true
  kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true
}

@test "it posts a critical alert to discord twice once with a mention of the user and a warning once with no mention" {
  setup_test "$tree"

  curl -fsS -o /dev/null -H 'Content-Type: application/json' --data @- "$(cat "$tree/alertmanager/url")/api/v2/alerts" << 'EOF'
[{"labels":{"alertname":"ImpHostDown","severity":"critical","namespace":"imp"},"annotations":{"summary":"imp-host has not answered for 5m."}},
{"labels":{"alertname":"NixieDegraded","severity":"warning","namespace":"nixie"},"annotations":{"summary":"nixie reports a slow dependency."}}]
EOF
  wait_for 90 "Alertmanager to post the three messages" test -f "$tree/discord/bodies/3.json"

  jq -c '{ content, title: .embeds[0].title }' "$tree"/discord/bodies/*.json > "$tree/posts"
  LC_ALL=C sort "$tree/posts" > "$tree/out"
  run -0 diff - "$tree/out" << 'EOF'
{"content":"","title":"[FIRING:1] ImpHostDown in imp"}
{"content":"","title":"[FIRING:1] NixieDegraded in nixie"}
{"content":"<@100000000000000001>","title":"[FIRING:1] ImpHostDown in imp"}
EOF
  refute [ -e "$tree/discord/unexpected" ]
}

@test "it cuts the title of an alert with a long name and namespace within discords 256 runes" {
  local name namespace
  setup_test "$tree"
  name="$(printf 'é%.0s' $(seq 300))"
  namespace="$(printf 'n%.0s' $(seq 100))"

  jq -n --arg name "$name" --arg namespace "$namespace" '[{
    labels: { alertname: $name, severity: "warning", namespace: $namespace, pod: ("p" * 200), container: ("c" * 200) },
    annotations: { summary: "A long alert." }
  }]' > "$tree/alert.json"
  curl -fsS -o /dev/null -H 'Content-Type: application/json' --data @"$tree/alert.json" "$(cat "$tree/alertmanager/url")/api/v2/alerts"
  wait_for 90 "Alertmanager to post the message" test -f "$tree/discord/bodies/1.json"

  jq -r '.embeds[0].title' "$tree/discord/bodies/1.json" > "$tree/out"
  printf '[FIRING:1] %s in %s\n' "${name:0:150}" "${namespace:0:63}" > "$tree/expected"
  run -0 diff "$tree/expected" "$tree/out"
  run -0 jq '.embeds[0].title | length' "$tree/discord/bodies/1.json"
  assert_output 228
  run -0 docker logs "$(cat "$tree/alertmanager/container")"
  refute_output --partial 'Truncated'
}
