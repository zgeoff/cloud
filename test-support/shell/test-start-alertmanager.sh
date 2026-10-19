#!/usr/bin/env bash
# Test for start-alertmanager.sh: start_alertmanager runs the pinned Alertmanager with the case's
# config, ready when it returns, as uid 65532 on a read-only root, and records its URL and
# container.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   bash test-support/shell/test-start-alertmanager.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-alertmanager.sh"

it_runs_the_cases_config_and_takes_an_alert() {
  create_case_tree 'docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true'
  setup_test "$tree"
  printf '%s' '{"route":{"receiver":"case"},"receivers":[{"name":"case"}]}' > "$tree/config/alertmanager.json"

  start_alertmanager "$tree/alertmanager" "$tree/config"

  curl -fsS -o /dev/null -H 'Content-Type: application/json' \
    --data '[{"labels":{"alertname":"CaseAlert"}}]' "$(cat "$tree/alertmanager/url")/api/v2/alerts"
  curl -fsS "$(cat "$tree/alertmanager/url")/api/v2/alerts" | jq -r '.[] | "\(.labels.alertname) \(.receivers[0].name)"' > "$tree/out"
  diff - "$tree/out" <<< 'CaseAlert case'
}

it_runs_alertmanager_as_uid_65532_on_a_read_only_root_with_no_capabilities() {
  local container
  create_case_tree 'docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true'
  setup_test "$tree"
  printf '%s' '{"route":{"receiver":"case"},"receivers":[{"name":"case"}]}' > "$tree/config/alertmanager.json"

  start_alertmanager "$tree/alertmanager" "$tree/config"

  container="$(cat "$tree/alertmanager/container")"
  assert_equals '65532 true [ALL] [no-new-privileges]' \
    "$(docker inspect --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$container")" \
    "the container's user, root and privileges"
}

setup_test() {
  mkdir "$1/alertmanager" "$1/config"
}

run_cases
