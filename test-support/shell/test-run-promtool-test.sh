#!/usr/bin/env bash
# Test for run-promtool-test.sh: run_promtool_test runs the pinned promtool's rule tests from the
# case's config directory, printing its output and returning its exit status, for a passing test
# and a failing one.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   bash test-support/shell/test-run-promtool-test.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-promtool-test.sh"

it_prints_success_and_returns_0_for_a_passing_rule_test() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '%s' '{"groups":[{"name":"case","rules":[{"alert":"CaseDown","expr":"case_up == 0"}]}]}' > "$tree/config/rules.json"
  printf '%s' '{"rule_files":["rules.json"],"tests":[{"interval":"1m","input_series":[{"series":"case_up","values":"0 0"}],
"alert_rule_test":[{"eval_time":"1m","alertname":"CaseDown","exp_alerts":[{"exp_labels":{}}]}]}]}' > "$tree/config/test.json"

  run_promtool_test "$tree/config" test.json > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
  SUCCESS

EOF
  assert_equals 0 "$status" "promtool's exit"
}

it_returns_1_for_a_failing_rule_test() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '%s' '{"groups":[{"name":"case","rules":[{"alert":"CaseDown","expr":"case_up == 0"}]}]}' > "$tree/config/rules.json"
  printf '%s' '{"rule_files":["rules.json"],"tests":[{"interval":"1m","input_series":[{"series":"case_up","values":"1 1"}],
"alert_rule_test":[{"eval_time":"1m","alertname":"CaseDown","exp_alerts":[{"exp_labels":{}}]}]}]}' > "$tree/config/test.json"

  run_promtool_test "$tree/config" test.json > "$tree/out" 2>&1 || status=$?

  assert_equals 1 "$status" "promtool's exit"
  grep -q '^  FAILED:$' "$tree/out"
}

# setup_test <tree>: the config directory, readable by the container's uid, unlike the 0700 tree
setup_test() {
  mkdir "$1/config"
}

run_cases
