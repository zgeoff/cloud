#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for the kube-prometheus-stack chart as the repo configures it: the pinned Helm renders the
# chart that metrics-chart.ts pins with the values build-metrics-values.ts builds, as Pulumi's Chart
# does. One case checks the Grafana Deployment's rollout strategy, which server-side apply merges
# into the live Deployment's: the apply owns only the strategy fields that the chart renders. One
# checks the spec of Grafana's volume claim, whose every change makes Pulumi replace it. One checks
# that the chart's node-exporter rules leave out the major page faults rule that the repo replaces.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='strategy' bash scripts/run-bats.sh alert-rules

# the first case pulls Helm's image and the chart on a cold cache
export BATS_TEST_TIMEOUT=180

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
  helm_image='alpine/helm:3.19.0@sha256:aef9b56f64e866207d9591d0abd8f6d767b36aadd12edf68f8a719716d9d29c9'
  # the sha256 of the chart archive at metrics-chart.ts's version, so a moved release fails the case
  chart_digest='dbd50ecc4b3c4a0231d8a7c766d4fd8690be4bf2230acb572849fae129797a23'
}

teardown() {
  stop_timeout_watchdog
}

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

@test "it renders the grafana deployment strategy as recreate with no rolling update block" {
  setup_test "$tree"

  run -0 --separate-stderr run_helm "$tree" template kube-prometheus-stack "/work/chart/$(ls "$tree/chart")" \
    --namespace observability -f /work/values.json \
    --show-only charts/grafana/templates/deployment.yaml

  assert_equal "$stderr" ''
  printf '%s\n' "$output" > "$tree/deployment.yaml"
  (cd "$repo" && run_in_case "$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const deployment = Bun.YAML.parse(await Bun.file(tree + '/deployment.yaml').text());
    await Bun.write(tree + '/strategy.json', JSON.stringify(deployment.spec.strategy) + '\n');
  ")
  run -0 diff - "$tree/strategy.json" << 'EOF'
{"type":"Recreate"}
EOF
}

@test "it renders the grafana claim on the retaining class with no volume name" {
  setup_test "$tree"

  run -0 --separate-stderr run_helm "$tree" template kube-prometheus-stack "/work/chart/$(ls "$tree/chart")" \
    --namespace observability -f /work/values.json \
    --show-only charts/grafana/templates/pvc.yaml

  assert_equal "$stderr" ''
  printf '%s\n' "$output" > "$tree/pvc.yaml"
  (cd "$repo" && run_in_case "$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const claim = Bun.YAML.parse(await Bun.file(tree + '/pvc.yaml').text());
    await Bun.write(tree + '/claim.json', JSON.stringify(claim.spec) + '\n');
  ")
  run -0 diff - "$tree/claim.json" << 'EOF'
{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"1Gi"}},"storageClassName":"local-path-retain"}
EOF
}

@test "it renders the node exporter alerts with no major page faults rule" {
  setup_test "$tree"

  run -0 --separate-stderr run_helm "$tree" template kube-prometheus-stack "/work/chart/$(ls "$tree/chart")" \
    --namespace observability -f /work/values.json \
    --show-only templates/prometheus/rules-1.14/node-exporter.yaml

  assert_equal "$stderr" ''
  printf '%s\n' "$output" > "$tree/rules.yaml"
  (cd "$repo" && run_in_case "$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const rule = Bun.YAML.parse(await Bun.file(tree + '/rules.yaml').text());
    const alerts = rule.spec.groups.flatMap((group) => group.rules.flatMap((r) => r.alert ?? []));
    const kept = ['NodeMemoryMajorPagesFaults', 'NodeMemoryHighUtilization'].map((name) => name + ' ' + alerts.includes(name));
    await Bun.write(tree + '/alerts.txt', kept.join('\n') + '\n');
  ")
  # build-alert-rules.ts builds the NodeMemoryMajorPagesFaults that replaces the chart's, and the
  # chart's other node alerts stay
  run -0 diff - "$tree/alerts.txt" << 'EOF'
NodeMemoryMajorPagesFaults false
NodeMemoryHighUtilization true
EOF
}
