#!/usr/bin/env bash
# Test for NixieDefinitionsStale in the real engine: promtool tests the rules that
# build-alert-rules.ts builds against git-sync's sync counters, shaped as the PodMonitor scrapes
# them from nixie-0's git-sync container. Each case compares promtool's whole output and exit
# status. infra/cluster/test-nixie-git-sync.sh checks that the pinned git-sync serves these
# counters.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='last good fetch' bash infra/observability/test-nixie-definitions-alert.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-promtool-test.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# setup_test <tree>: the rules as JSON from the repo's builder
setup_test() {
  mkdir -p "$1/config"
  (cd "$repo" && TREE="$1" bun -e "
    import { buildAlertRules } from './infra/observability/build-alert-rules.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: buildAlertRules({ nixieReadinessURL: 'http://nixie.nixie.svc.cluster.local:8080/health/ready' }) }));
  ")
}

it_fires_within_15_minutes_of_the_last_good_fetch_and_names_its_time() {
  local status=0
  create_case_tree
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

  run_promtool_test "$tree/config" test.json > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_stays_quiet_while_git_sync_fetches_each_minute_between_failed_fetches() {
  local status=0
  create_case_tree
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

  run_promtool_test "$tree/config" test.json > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_fires_with_no_last_good_fetch_when_git_sync_reports_no_fetch() {
  local status=0
  create_case_tree
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

  run_promtool_test "$tree/config" test.json > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

run_cases
