#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for run-promtool-test.sh: run_promtool_test runs the pinned promtool's rule tests from the
# case's config directory, printing its output and returning its exit status, for a passing test
# and a failing one.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='failing' bash scripts/run-bats.sh alert-rules

# pulling the image on a cold cache takes longer than the shared 30 seconds
export BATS_TEST_TIMEOUT=180

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'run-promtool-test.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  # the config directory, readable by the container's uid, unlike the 0700 test directory
  mkdir "$tree/config"
}

teardown() {
  stop_timeout_watchdog
}

@test "it prints success and returns 0 for a passing rule test" {
  printf '%s' '{"groups":[{"name":"case","rules":[{"alert":"CaseDown","expr":"case_up == 0"}]}]}' > "$tree/config/rules.json"
  printf '%s' '{"rule_files":["rules.json"],"tests":[{"interval":"1m","input_series":[{"series":"case_up","values":"0 0"}],
"alert_rule_test":[{"eval_time":"1m","alertname":"CaseDown","exp_alerts":[{"exp_labels":{}}]}]}]}' > "$tree/config/test.json"

  run -0 run_promtool_test "$tree/config" test.json

  assert_output '  SUCCESS'
}

@test "it returns 1 for a failing rule test" {
  printf '%s' '{"groups":[{"name":"case","rules":[{"alert":"CaseDown","expr":"case_up == 0"}]}]}' > "$tree/config/rules.json"
  printf '%s' '{"rule_files":["rules.json"],"tests":[{"interval":"1m","input_series":[{"series":"case_up","values":"1 1"}],
"alert_rule_test":[{"eval_time":"1m","alertname":"CaseDown","exp_alerts":[{"exp_labels":{}}]}]}]}' > "$tree/config/test.json"

  run -1 run_promtool_test "$tree/config" test.json

  assert_line '  FAILED:'
}
