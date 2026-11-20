#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for NixieDefinitionsStale in the real engine: promtool tests the rules that
# build-alert-rules.ts builds against git-sync's sync counters, shaped as the PodMonitor scrapes
# them from nixie-0's git-sync container. Each case compares promtool's whole output and exit
# status. infra/cluster/nixie-git-sync.bats checks that the pinned git-sync serves these
# counters.
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

# setup_test <tree>: the rules as JSON from the repo's builder
setup_test() {
  mkdir -p "$1/config"
  (cd "$repo" && TREE="$1" bun -e "
    import { buildAlertRules } from './infra/observability/build-alert-rules.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: buildAlertRules({ nixieReadinessURL: 'http://nixie.nixie.svc.cluster.local:8080/health/ready' }) }));
  ")
}

@test "it fires within 15 minutes of the last good fetch and names its time" {
  setup_test "$tree"
  # one first sync, a no-op sync each minute until 30m, then a failed sync each minute
  cat > "$tree/config/test.json" << 'EOF'
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"success\"}","values":"1x60"},
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"noop\"}","values":"0+1x30 30x30"},
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"error\"}","values":"0x30 1+1x30"}],
"alert_rule_test":[
{"eval_time":"43m","alertname":"NixieDefinitionsStale","exp_alerts":[]},
{"eval_time":"45m","alertname":"NixieDefinitionsStale","exp_alerts":[
{"exp_labels":{"severity":"warning"},
"exp_annotations":{"summary":"nixie's git-sync reports no good fetch of the definitions in the last 10 minutes, so nixie serves the checkout of its last good fetch: 1970-01-01 00:30:00 +0000 UTC."}}]}]}]}
EOF

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it stays quiet while git sync fetches each minute between failed fetches" {
  setup_test "$tree"
  cat > "$tree/config/test.json" << 'EOF'
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"success\"}","values":"1x60"},
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"noop\"}","values":"0+1x60"},
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"error\"}","values":"0+1x60"}],
"alert_rule_test":[
{"eval_time":"50m","alertname":"NixieDefinitionsStale","exp_alerts":[]}]}]}
EOF

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it fires with no last good fetch when git sync reports no fetch" {
  setup_test "$tree"
  # git-sync has failed every sync since nixie-0 started, so its counter of good syncs never appears
  cat > "$tree/config/test.json" << 'EOF'
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"git_sync_count_total{namespace=\"nixie\",pod=\"nixie-0\",container=\"git-sync\",status=\"error\"}","values":"1+1x20"}],
"alert_rule_test":[
{"eval_time":"6m","alertname":"NixieDefinitionsStale","exp_alerts":[
{"exp_labels":{"severity":"warning","namespace":"nixie","container":"git-sync"},
"exp_annotations":{"summary":"nixie's git-sync reports no good fetch of the definitions in the last 10 minutes, so nixie serves the checkout of its last good fetch: none in the last day."}}]}]}]}
EOF

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}
