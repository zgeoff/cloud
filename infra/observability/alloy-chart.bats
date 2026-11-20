#!/usr/bin/env bats
# bats file_tags=suite:alert-rules
# Test for the Alloy chart as the repo configures it: the pinned Helm renders the chart that
# alloy-chart.ts pins with the values build-alloy-values.ts builds, as Pulumi's Chart does. One case
# checks that the chart creates no ConfigMap and mounts Alloy's config from the ConfigMap the values
# name, which Pulumi creates and names itself. The other checks the Alloy container's command, which
# seeds or repairs Alloy's read positions before Alloy starts, and its volumes.
#
#   bash scripts/run-bats.sh alert-rules
#   CASE='ConfigMap' bash scripts/run-bats.sh alert-rules

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
  # the sha256 of the chart archive at alloy-chart.ts's version, so a moved release fails the case
  chart_digest='bfdda6cb770c3526444897b9cb5a4fb33711c608d364d9e7857ec699a2fff4fb'
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
# bin, the pinned chart's archive, and the values as the repo builds them, naming the ConfigMap
# alloy-config-1a2b3c4d, as Pulumi names one
setup_test() {
  local tree="$1" tool
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/chart"
  for tool in bun docker jq; do
    ln -s "$(command -v "$tool")" "$tree/bin/$tool"
  done
  (cd "$repo" && run_in_case "$tree" bun -e "
    import { alloyChart } from './infra/observability/alloy-chart.ts';
    import { buildAlloyValues } from './infra/observability/build-alloy-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/chart.json', JSON.stringify(alloyChart));
    await Bun.write(tree + '/values.json', JSON.stringify(buildAlloyValues('alloy-config-1a2b3c4d')));
  ")
  run_in_case "$tree" docker pull -q "$helm_image" > /dev/null
  run_helm "$tree" pull "$(jq -r .chart "$tree/chart.json")" \
    --repo "$(jq -r .repositoryOpts.repo "$tree/chart.json")" \
    --version "$(jq -r .version "$tree/chart.json")" -d /work/chart
  (cd "$tree/chart" && echo "$chart_digest  $(jq -r '.chart + "-" + .version' "$tree/chart.json").tgz" | sha256sum -c --quiet)
}

@test "it renders no configmap and mounts alloys config from the configmap the values name" {
  setup_test "$tree"

  run -0 --separate-stderr run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json

  assert_equal "$stderr" ''
  printf '%s\n' "$output" > "$tree/chart.yaml"
  # the kinds the chart renders that hold config, the ConfigMap the DaemonSet's config volume
  # names, and the file Alloy runs
  (cd "$repo" && run_in_case "$tree" bun -e "
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
  run -0 diff - "$tree/config.txt" << 'EOF'
configmaps 0
secrets 0
config volume alloy-config-1a2b3c4d
config file /etc/alloy/config.alloy
EOF
}

@test "it renders the alloy container with the entry script before the charts run arguments over the nodes log and storage directories" {
  setup_test "$tree"

  run -0 --separate-stderr run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json --show-only templates/controllers/daemonset.yaml

  assert_equal "$stderr" ''
  printf '%s\n' "$output" > "$tree/daemonset.yaml"
  # the Alloy container's command against the one build-alloy-values.ts builds, its first arguments,
  # any init container, and each pod volume the entry script reads or writes with its host path
  (cd "$repo" && run_in_case "$tree" bun -e "
    import { buildAlloyValues } from './infra/observability/build-alloy-values.ts';
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
  run -0 diff - "$tree/alloy.txt" << 'EOF'
command as built
args run /etc/alloy/config.alloy --storage.path=/var/lib/alloy
init containers 0
varlog /var/log ro /var/log
storage /var/lib/alloy rw /var/lib/alloy
EOF
}
