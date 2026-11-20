#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for NodeMemoryMajorPagesFaults in the real engine: promtool tests the rule that
# build-alert-rules.ts builds against node-exporter's major fault and pressure stall counters. The
# faults rise by 83,000 a minute, about the rate that a wake's 250,000 faults every 3 minutes
# averages. Each case compares promtool's whole output and exit status.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='memory' bash scripts/run-bats.sh alert-rules

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
    await Bun.write(tree + '/config/rules.json', JSON.stringify({ groups: buildAlertRules() }));
  ")
}

# write_test <tree> <faults> <memory waiting> <io stalled> <alert tests>: a promtool test of the
# three counters, given as promtool series values a minute apart, and the alert tests as JSON
write_test() {
  cat > "$1/config/test.json" << EOF
{"rule_files":["rules.json"],"evaluation_interval":"30s","tests":[{"interval":"1m",
"input_series":[
{"series":"node_vmstat_pgmajfault{job=\"node-exporter\",instance=\"stu-test:9100\"}","values":"$2"},
{"series":"node_pressure_memory_waiting_seconds_total{job=\"node-exporter\",instance=\"stu-test:9100\"}","values":"$3"},
{"series":"node_pressure_io_stalled_seconds_total{job=\"node-exporter\",instance=\"stu-test:9100\"}","values":"$4"}],
"alert_rule_test":$5}]}
EOF
}

@test "it stays silent on the wake faults while nothing stalls" {
  setup_test "$tree"
  # 1% of the time waiting on memory and 0.2% stalled on IO, as during the wake bursts
  write_test "$tree" '0+83000x60' '0+0.6x60' '0+0.12x60' '[
{"eval_time":"10m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[]},
{"eval_time":"60m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[]}]'

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it fires within 10 minutes of the faults meeting a memory stall" {
  setup_test "$tree"
  # from 10m, 20% of the time waiting on memory
  write_test "$tree" '0+83000x60' '0+0.6x10 6+12x50' '0+0.12x60' '[
{"eval_time":"13m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[]},
{"eval_time":"20m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[
{"exp_labels":{"severity":"warning","job":"node-exporter","instance":"stu-test:9100"},
"exp_annotations":{"summary":"geoffcloud takes 1.383k major page faults a second while memory or IO stalls its tasks."}}]}]'

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it fires within 10 minutes of the faults meeting an io stall" {
  setup_test "$tree"
  # from 10m, every task stalled on IO 15% of the time
  write_test "$tree" '0+83000x60' '0+0.6x60' '0+0.12x10 1.2+9x50' '[
{"eval_time":"13m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[]},
{"eval_time":"20m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[
{"exp_labels":{"severity":"warning","job":"node-exporter","instance":"stu-test:9100"},
"exp_annotations":{"summary":"geoffcloud takes 1.383k major page faults a second while memory or IO stalls its tasks."}}]}]'

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it stays silent on a memory stall without the faults" {
  setup_test "$tree"
  # 3 faults a second, the rate between bursts, beside 20% of the time waiting on memory
  write_test "$tree" '0+180x60' '0+12x60' '0+0.12x60' '[
{"eval_time":"60m","alertname":"NodeMemoryMajorPagesFaults","exp_alerts":[]}]'

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}
