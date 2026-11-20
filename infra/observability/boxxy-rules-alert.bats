#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for BoxxyRulesStale in the real engine: promtool tests the rules that build-alert-rules.ts
# builds against git-sync's sync counters, shaped as the PodMonitor scrapes them from boxxy-0's
# rules-sync container. Each case compares promtool's whole output and exit status.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='last good fetch' bash scripts/run-bats.sh alert-rules

# promtool and the images it runs in take longer than the shared 30 seconds on a cold image cache
export BATS_TEST_TIMEOUT=180

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/run-promtool-test.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the rules as JSON from the repo's builder, with the boxxy server deployed
setup_test() {
  mkdir -p "$1/config"
  (cd "$repo" && TREE="$1" bun -e "
    import { buildAlertRules } from './infra/observability/build-alert-rules.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: buildAlertRules({ boxxyRulesSync: true }) }));
  ")
}

@test "it fires within 15 minutes of the last good fetch and names its time" {
  setup_test "$tree"
  # one first sync, a no-op sync each minute until 30m, then a failed sync each minute
  cat > "$tree/config/test.json" << 'EOF'
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"git_sync_count_total{namespace=\"boxxy\",pod=\"boxxy-0\",container=\"rules-sync\",status=\"success\"}","values":"1x60"},
{"series":"git_sync_count_total{namespace=\"boxxy\",pod=\"boxxy-0\",container=\"rules-sync\",status=\"noop\"}","values":"0+1x30 30x30"},
{"series":"git_sync_count_total{namespace=\"boxxy\",pod=\"boxxy-0\",container=\"rules-sync\",status=\"error\"}","values":"0x30 1+1x30"}],
"alert_rule_test":[
{"eval_time":"43m","alertname":"BoxxyRulesStale","exp_alerts":[]},
{"eval_time":"45m","alertname":"BoxxyRulesStale","exp_alerts":[
{"exp_labels":{"severity":"warning"},
"exp_annotations":{"summary":"The boxxy server's rules sidecar reports no good fetch of the rules repository in the last 10 minutes, so the server loads the checkout of its last good fetch: 1970-01-01 00:30:00 +0000 UTC."}}]}]}]}
EOF

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it fires with no last good fetch when git sync reports no fetch" {
  setup_test "$tree"
  # the sidecar has failed every sync since boxxy-0 started, so its counter of good syncs never
  # appears
  cat > "$tree/config/test.json" << 'EOF'
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"git_sync_count_total{namespace=\"boxxy\",pod=\"boxxy-0\",container=\"rules-sync\",status=\"error\"}","values":"1+1x20"}],
"alert_rule_test":[
{"eval_time":"6m","alertname":"BoxxyRulesStale","exp_alerts":[
{"exp_labels":{"severity":"warning","namespace":"boxxy","container":"rules-sync"},
"exp_annotations":{"summary":"The boxxy server's rules sidecar reports no good fetch of the rules repository in the last 10 minutes, so the server loads the checkout of its last good fetch: none in the last day."}}]}]}]}
EOF

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}
