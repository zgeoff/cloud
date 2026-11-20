#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for start-alertmanager.sh: start_alertmanager runs the pinned Alertmanager with the case's
# config, ready when it returns, as uid 65532 on a read-only root, and records its URL and
# container.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='uid' bash scripts/run-bats.sh alert-rules

# pulling the image on a cold cache takes longer than the shared 30 seconds
export BATS_TEST_TIMEOUT=180

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'start-alertmanager.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  mkdir "$tree/alertmanager" "$tree/config"
  printf '%s' '{"route":{"receiver":"case"},"receivers":[{"name":"case"}]}' > "$tree/config/alertmanager.json"
}

# each step safe when start_alertmanager stopped before it wrote the container
teardown() {
  stop_timeout_watchdog
  docker rm -f "$(cat "$tree/alertmanager/container" 2> /dev/null)" > /dev/null 2>&1 || true
}

# print_alerts <url>: each alert's name and first receiver, one per line
print_alerts() {
  curl -fsS "$1/api/v2/alerts" | jq -r '.[] | "\(.labels.alertname) \(.receivers[0].name)"'
}

@test "it runs the cases config and takes an alert" {
  start_alertmanager "$tree/alertmanager" "$tree/config"
  url="$(cat "$tree/alertmanager/url")"

  curl -fsS -o /dev/null -H 'Content-Type: application/json' \
    --data '[{"labels":{"alertname":"CaseAlert"}}]' "$url/api/v2/alerts"

  run -0 print_alerts "$url"
  assert_output 'CaseAlert case'
}

@test "it runs alertmanager as uid 65532 on a read-only root with no capabilities" {
  start_alertmanager "$tree/alertmanager" "$tree/config"

  run -0 docker inspect --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$(cat "$tree/alertmanager/container")"

  assert_output '65532 true [ALL] [no-new-privileges]'
}
