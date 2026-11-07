#!/usr/bin/env bash
# Test for the kube-prometheus-stack chart as the repo configures it: the pinned Helm renders the
# chart that metrics-chart.ts pins with the values build-metrics-values.ts builds, as Pulumi's Chart
# does. The case checks the Grafana Deployment's rollout strategy, which server-side apply merges
# into the live Deployment's: the apply owns only the strategy fields that the chart renders.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='strategy' bash infra/observability/test-metrics-chart.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helm_image='alpine/helm:3.19.0@sha256:aef9b56f64e866207d9591d0abd8f6d767b36aadd12edf68f8a719716d9d29c9'
# the sha256 of the chart archive at metrics-chart.ts's version, so a moved release fails the case
chart_digest='dbd50ecc4b3c4a0231d8a7c766d4fd8690be4bf2230acb572849fae129797a23'

# run_in_case <tree> <command>...: <command> with none of the caller's environment, so a
# DOCKER_HOST or DOCKER_CONTEXT never picks the daemon, and with PATH, HOME and TMPDIR in the tree
run_in_case() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" TREE="$tree" "$@"
}

# run_helm <tree> <arg>...: the pinned Helm as the caller's user, with the case tree at /work
run_helm() {
  local tree="$1"
  shift
  run_in_case "$tree" docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$tree:/work" -w /work "$helm_image" "$@"
}

# setup_test <tree>: the case's bin, home and tmp folders, with the tools the case runs linked into
# bin, the pinned chart's archive, and the values as the repo builds them
setup_test() {
  local tree="$1" tool
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/chart"
  for tool in bun docker jq; do
    ln -s "$(command -v "$tool")" "$tree/bin/$tool"
  done
  (cd "$repo" && run_in_case "$tree" bun -e "
    import { buildMetricsValues } from './infra/observability/build-metrics-values.ts';
    import { metricsChart } from './infra/observability/metrics-chart.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/chart.json', JSON.stringify(metricsChart));
    const values = buildMetricsValues({ password: 'grafana-test-password', nodePort: 30300 });
    await Bun.write(tree + '/values.json', JSON.stringify(values));
  ")
  run_in_case "$tree" docker pull -q "$helm_image" > /dev/null
  run_helm "$tree" pull "$(jq -r .chart "$tree/chart.json")" \
    --repo "$(jq -r .repositoryOpts.repo "$tree/chart.json")" \
    --version "$(jq -r .version "$tree/chart.json")" -d /work/chart
  (cd "$tree/chart" && echo "$chart_digest  $(jq -r '.chart + "-" + .version' "$tree/chart.json").tgz" | sha256sum -c --quiet)
}

it_renders_the_grafana_deployment_strategy_with_its_rolling_update_block_and_no_surge_pod() {
  local status=0
  create_case_tree
  setup_test "$tree"

  run_helm "$tree" template kube-prometheus-stack "/work/chart/$(ls "$tree/chart")" \
    --namespace observability -f /work/values.json \
    --show-only charts/grafana/templates/deployment.yaml > "$tree/deployment.yaml" 2> "$tree/err" || status=$?

  assert_equals 0 "$status" 'helm template exit'
  diff /dev/null "$tree/err"
  (cd "$repo" && run_in_case "$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const deployment = Bun.YAML.parse(await Bun.file(tree + '/deployment.yaml').text());
    await Bun.write(tree + '/strategy.json', JSON.stringify(deployment.spec.strategy) + '\n');
  ")
  diff - "$tree/strategy.json" << 'EOF'
{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}
EOF
}

run_cases
