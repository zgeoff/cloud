#!/usr/bin/env bash
# Test for start-alloy.sh: start_alloy runs the pinned Alloy with the case's config and log
# directory, ready when it returns, as uid 65532 on a read-only root, and records its URL and
# container.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   bash test-support/shell/test-start-alloy.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/has-metric.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-alloy.sh"

it_runs_the_cases_config_over_its_log_directory() {
  tree="$(mktemp -d)"
  trap 'docker rm -f "$(cat "$tree/alloy/container" 2> /dev/null)" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  cat > "$tree/config/config.alloy" << 'EOF'
loki.source.file "case" {
  targets = [{__path__ = "/logs/*.log"}]
  file_match {
    enabled = true
  }
  forward_to = [loki.process.case.receiver]
}

loki.process "case" {
  forward_to = []
  stage.metrics {
    metric.counter {
      name      = "case_lines_total"
      match_all = true
      action    = "inc"
    }
  }
}
EOF
  printf '%s\n' 'first' 'second' > "$tree/logs/case.log"

  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"

  wait_for 30 "Alloy to count both lines" has_metric "$(cat "$tree/alloy/url")" '^loki_process_custom_case_lines_total{.*} 2$'
}

it_runs_alloy_as_uid_65532_on_a_read_only_root_with_no_capabilities() {
  local container
  tree="$(mktemp -d)"
  trap 'docker rm -f "$(cat "$tree/alloy/container" 2> /dev/null)" > /dev/null 2>&1 || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf '%s\n' 'logging {' '  level = "warn"' '}' > "$tree/config/config.alloy"

  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"

  container="$(cat "$tree/alloy/container")"
  assert_equals '65532 true [ALL] [no-new-privileges]' \
    "$(docker inspect --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$container")" \
    "the container's user, root and privileges"
  curl -fsS -o /dev/null "$(cat "$tree/alloy/url")/-/ready"
}

setup_test() {
  mkdir "$1/alloy" "$1/config" "$1/logs"
}

run_cases
