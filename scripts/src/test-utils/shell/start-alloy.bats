#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for start-alloy.sh: start_alloy runs the pinned Alloy with the case's config and log
# directory, ready when it returns, as uid 65532 on a read-only root, and records its URL and
# container.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='uid' bash scripts/run-bats.sh alert-rules

# a case waits for Alloy to start, restart and count, and the first one pulls its image
export BATS_TEST_TIMEOUT=240

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'wait-for.sh'
  load 'has-metric.sh'
  load 'start-alloy.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  volume="alloy-storage-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  mkdir "$tree/alloy" "$tree/alloy-again" "$tree/config" "$tree/logs"
}

# each step safe when the case stopped before it
teardown() {
  stop_timeout_watchdog
  docker rm -f "$(cat "$tree/alloy/container" 2> /dev/null)" "$(cat "$tree/alloy-again/container" 2> /dev/null)" > /dev/null 2>&1 || true
  docker volume rm "$volume" > /dev/null 2>&1 || true
}

# write_counting_config: an Alloy config that counts each line of /logs/*.log in case_lines_total
write_counting_config() {
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
}

@test "it runs the cases config over its log directory" {
  write_counting_config
  printf '%s\n' 'first' 'second' > "$tree/logs/case.log"

  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"

  wait_for 30 "Alloy to count both lines" has_metric "$(cat "$tree/alloy/url")" '^loki_process_custom_case_lines_total{.*} 2$'
}

@test "it runs alloy as uid 65532 on a read-only root with no capabilities" {
  printf '%s\n' 'logging {' '  level = "warn"' '}' > "$tree/config/config.alloy"

  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"

  run -0 docker inspect --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$(cat "$tree/alloy/container")"
  assert_output '65532 true [ALL] [no-new-privileges]'
  run -0 curl -fsS -o /dev/null "$(cat "$tree/alloy/url")/-/ready"
}

@test "it resumes from the read positions an earlier start kept in the same storage volume" {
  write_counting_config
  printf '%s\n' 'first' 'second' > "$tree/logs/case.log"
  start_alloy "$tree/alloy" "$tree/config" "$tree/logs" "$volume"
  wait_for 30 "Alloy to count both lines" has_metric "$(cat "$tree/alloy/url")" '^loki_process_custom_case_lines_total{.*} 2$'
  docker stop "$(cat "$tree/alloy/container")" > /dev/null
  printf '%s\n' 'third' >> "$tree/logs/case.log"

  start_alloy "$tree/alloy-again" "$tree/config" "$tree/logs" "$volume"

  wait_for 30 "Alloy to count the third line" has_metric "$(cat "$tree/alloy-again/url")" '^loki_process_custom_case_lines_total{.*} 1$'
}

@test "it runs the entry script as alloys user over the logs and the storage before each alloy start in the container" {
  cat > "$tree/config/config.alloy" << 'EOF'
local.file "runs" {
  filename = "/storage/runs.txt"
}
EOF
  printf '%s\n' 'first' > "$tree/logs/case.log"
  # shellcheck disable=SC2016 # expanded by the entry script's sh
  start_alloy "$tree/alloy" "$tree/config" "$tree/logs" "$volume" 'echo "$(id -u) $(cat /logs/case.log)" >> /storage/runs.txt'

  docker restart "$(cat "$tree/alloy/container")" > /dev/null

  wait_for 60 "Alloy to report ready again" curl -q --noproxy '*' -fs -o /dev/null "$(cat "$tree/alloy/url")/-/ready"
  run -0 docker exec "$(cat "$tree/alloy/container")" cat /storage/runs.txt
  assert_output $'65532 first\n65532 first'
}
