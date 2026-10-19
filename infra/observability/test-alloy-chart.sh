#!/usr/bin/env bash
# Test for the Alloy chart as the repo configures it: the pinned Helm renders the chart that
# alloy-chart.ts pins with the values alloy-values.ts builds, as Pulumi's Chart does. One case checks
# that the chart creates no ConfigMap and mounts Alloy's config from the ConfigMap the values name,
# which Pulumi creates and names itself. The other checks the Alloy container's command, which seeds
# or repairs Alloy's read positions before Alloy starts, and its volumes.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='ConfigMap' bash infra/observability/test-alloy-chart.sh
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
# the sha256 of the chart archive at alloy-chart.ts's version, so a moved release fails the case
chart_digest='bfdda6cb770c3526444897b9cb5a4fb33711c608d364d9e7857ec699a2fff4fb'

# run_helm <tree> <arg>...: the pinned Helm as the caller's user, with the case tree at /work
run_helm() {
  local tree="$1"
  shift
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$tree:/work" -w /work "$helm_image" "$@"
}

# setup_test <tree>: the pinned chart's archive and the values as the repo builds them, naming the
# ConfigMap alloy-config-1a2b3c4d, as Pulumi names one
setup_test() {
  local tree="$1"
  mkdir "$tree/chart"
  (cd "$repo" && TREE="$tree" bun -e "
    import { alloyChart } from './infra/observability/alloy-chart.ts';
    import { buildAlloyValues } from './infra/observability/alloy-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/chart.json', JSON.stringify(alloyChart));
    await Bun.write(tree + '/values.json', JSON.stringify(buildAlloyValues('alloy-config-1a2b3c4d')));
  ")
  docker pull -q "$helm_image" > /dev/null
  run_helm "$tree" pull "$(jq -r .chart "$tree/chart.json")" \
    --repo "$(jq -r .repositoryOpts.repo "$tree/chart.json")" \
    --version "$(jq -r .version "$tree/chart.json")" -d /work/chart
  (cd "$tree/chart" && echo "$chart_digest  $(jq -r '.chart + "-" + .version' "$tree/chart.json").tgz" | sha256sum -c --quiet)
}

it_renders_no_configmap_and_mounts_alloys_config_from_the_configmap_the_values_name() {
  local status=0
  create_case_tree
  setup_test "$tree"

  run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json > "$tree/chart.yaml" 2> "$tree/err" || status=$?

  assert_equals 0 "$status" 'helm template exit'
  diff /dev/null "$tree/err"
  # the kinds the chart renders that hold config, the ConfigMap the DaemonSet's config volume
  # names, and the file Alloy runs
  (cd "$repo" && TREE="$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const objects = Bun.YAML.parse(await Bun.file(tree + '/chart.yaml').text()).filter(Boolean);
    const daemonSet = objects.find((object) => object.kind === 'DaemonSet');
    const pod = daemonSet.spec.template.spec;
    const alloy = pod.containers.find((container) => container.name === 'alloy');
    const config = pod.volumes.find((volume) => volume.name === 'config');
    const lines = [
      'configmaps ' + objects.filter((object) => object.kind === 'ConfigMap').length,
      'secrets ' + objects.filter((object) => object.kind === 'Secret').length,
      'config volume ' + config.configMap.name,
      'config file ' + alloy.args[1],
    ];
    await Bun.write(tree + '/config.txt', lines.join('\n') + '\n');
  ")
  diff - "$tree/config.txt" << 'EOF'
configmaps 0
secrets 0
config volume alloy-config-1a2b3c4d
config file /etc/alloy/config.alloy
EOF
}

it_renders_the_alloy_container_with_the_entry_script_before_the_charts_run_arguments_over_the_nodes_log_and_storage_directories() {
  local status=0
  create_case_tree
  setup_test "$tree"

  run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json --show-only templates/controllers/daemonset.yaml > "$tree/daemonset.yaml" 2> "$tree/err" || status=$?

  assert_equals 0 "$status" 'helm template exit'
  diff /dev/null "$tree/err"
  # the Alloy container's command against the one alloy-values.ts builds, its first arguments, any
  # init container, and each pod volume the entry script reads or writes with its host path
  (cd "$repo" && TREE="$tree" bun -e "
    import { buildAlloyValues } from './infra/observability/alloy-values.ts';
    const tree = process.env.TREE ?? '';
    const pod = Bun.YAML.parse(await Bun.file(tree + '/daemonset.yaml').text()).spec.template.spec;
    const alloy = pod.containers.find((container) => container.name === 'alloy');
    const built = buildAlloyValues('alloy-config-1a2b3c4d').alloy.command;
    const lines = [
      'command ' + (Bun.deepEquals(alloy.command, built) ? 'as built' : JSON.stringify(alloy.command)),
      'args ' + alloy.args.slice(0, 3).join(' '),
      'init containers ' + (pod.initContainers?.length ?? 0),
    ];
    for (const mount of alloy.volumeMounts.filter((candidate) => ['varlog', 'storage'].includes(candidate.name))) {
      const volume = pod.volumes.find((candidate) => candidate.name === mount.name);
      lines.push([mount.name, mount.mountPath, mount.readOnly ? 'ro' : 'rw', volume?.hostPath?.path].join(' '));
    }
    await Bun.write(tree + '/alloy.txt', lines.join('\n') + '\n');
  ")
  diff - "$tree/alloy.txt" << 'EOF'
command as built
args run /etc/alloy/config.alloy --storage.path=/var/lib/alloy
init containers 0
varlog /var/log ro /var/log
storage /var/lib/alloy rw /var/lib/alloy
EOF
}

run_cases
