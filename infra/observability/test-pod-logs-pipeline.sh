#!/usr/bin/env bash
# Test for the pod-log pipeline in the pinned Alloy: Alloy runs the pipeline
# build-pod-logs-pipeline.ts builds over one container's log in the case tree, written in the
# kubelet's CRI format, with a target shaped as discovery.kubernetes gives it, and with an empty
# position store, as a start with a new or wiped store has. loki.echo stands in for Loki and prints
# each entry's labels and line to Alloy's log, which each case compares.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='labelled' bash infra/observability/test-pod-logs-pipeline.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/has-metric.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/start-alloy.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log_dir='shop_web-7f9c8d6b5-q4z2m_3b1f0c2e-5a7d-4c19-9e2b-0d6f8a1c4e73/web'

# setup_test <tree>: the pipeline as the repo builds it, fed one pod's container and printing each
# entry, the directory Alloy records itself in, and the container's empty log
setup_test() {
  local tree="$1"
  mkdir -p "$tree/config" "$tree/alloy" "$tree/logs/$log_dir"
  : > "$tree/logs/$log_dir/0.log"
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildPodLogsPipeline } from './infra/observability/build-pod-logs-pipeline.ts';
    const tree = process.env.TREE ?? '';
    const targets = '[{' + [
      '\"__address__\" = \"10.42.0.17:8080\"',
      '\"__meta_kubernetes_namespace\" = \"shop\"',
      '\"__meta_kubernetes_pod_name\" = \"web-7f9c8d6b5-q4z2m\"',
      '\"__meta_kubernetes_pod_uid\" = \"3b1f0c2e-5a7d-4c19-9e2b-0d6f8a1c4e73\"',
      '\"__meta_kubernetes_pod_container_name\" = \"web\"',
      '\"__meta_kubernetes_pod_container_port_number\" = \"8080\"',
    ].join(', ') + '}]';
    const pipeline = buildPodLogsPipeline({ targets, podLogRoot: '/logs', forwardTo: 'loki.echo.loki.receiver' });
    await Bun.write(tree + '/config/config.alloy', pipeline + '\nloki.echo \"loki\" {}\n');
  ")
}

# teardown: each step safe when setup_test or the case stopped before it
teardown() {
  docker rm -f "$(cat "$tree/alloy/container" 2> /dev/null)" > /dev/null 2>&1 || true
  rm -rf "$tree" || true
}

it_ships_each_line_the_container_writes_once_alloy_tails_its_file_labelled_as_a_pod_stream_with_partial_lines_joined() {
  local now
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"
  wait_for 60 "Alloy to tail the container's log" has_metric "$(cat "$tree/alloy/url")" '^loki_source_file_files_active_total{.*} 1$'
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"

  sed "s/@NOW@/$now/" >> "$tree/logs/$log_dir/0.log" << 'EOF'
@NOW@ stdout F order 41 placed
@NOW@ stderr P payment for order 41
@NOW@ stderr F  timed out
@NOW@ stdout F order 42 placed
EOF

  # shellcheck disable=SC2016 # expanded by the inner sh
  wait_for 30 "Alloy to ship the last line" sh -c 'docker logs "$1" 2>&1 | grep -qF "entry=\"order 42 placed\""' _ "$(cat "$tree/alloy/container")"
  docker logs "$(cat "$tree/alloy/container")" 2>&1 |
    sed -n 's/.*component_id=loki\.echo\.loki labels="\(.*\)" entry="\(.*\)" entry_timestamp=.*/\1 \2/p' > "$tree/entries"
  diff - "$tree/entries" << 'EOF'
{container=\"web\", instance=\"shop/web-7f9c8d6b5-q4z2m:web\", job=\"loki.source.kubernetes.pods\", namespace=\"shop\", pod=\"web-7f9c8d6b5-q4z2m\"} order 41 placed
{container=\"web\", instance=\"shop/web-7f9c8d6b5-q4z2m:web\", job=\"loki.source.kubernetes.pods\", namespace=\"shop\", pod=\"web-7f9c8d6b5-q4z2m\"} payment for order 41 timed out
{container=\"web\", instance=\"shop/web-7f9c8d6b5-q4z2m:web\", job=\"loki.source.kubernetes.pods\", namespace=\"shop\", pod=\"web-7f9c8d6b5-q4z2m\"} order 42 placed
EOF
}

it_reads_none_of_the_lines_the_container_wrote_before_alloy_started_with_an_empty_position_store() {
  local before now
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  before="$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%S.000000000Z)"
  sed "s/@BEFORE@/$before/" >> "$tree/logs/$log_dir/0.log" << 'EOF'
@BEFORE@ stdout F listening on :8080
@BEFORE@ stderr F order 40 failed
EOF

  start_alloy "$tree/alloy" "$tree/config" "$tree/logs"
  wait_for 60 "Alloy to tail the container's log" has_metric "$(cat "$tree/alloy/url")" '^loki_source_file_files_active_total{.*} 1$'
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"
  echo "$now stdout F order 41 placed" >> "$tree/logs/$log_dir/0.log"

  # shellcheck disable=SC2016 # expanded by the inner sh
  wait_for 30 "Alloy to ship the new line" sh -c 'docker logs "$1" 2>&1 | grep -qF "entry=\"order 41 placed\""' _ "$(cat "$tree/alloy/container")"
  docker logs "$(cat "$tree/alloy/container")" 2>&1 |
    sed -n 's/.*component_id=loki\.echo\.loki labels=".*" entry="\(.*\)" entry_timestamp=.*/\1/p' > "$tree/entries"
  diff - "$tree/entries" << 'EOF'
order 41 placed
EOF
}

run_cases
