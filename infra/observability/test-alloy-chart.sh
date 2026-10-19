#!/usr/bin/env bash
# Test for the Alloy chart's ConfigMap: the pinned Helm renders the chart that alloy-chart.ts pins
# with the values alloy-values.ts builds, as Pulumi's Chart does, and the case compares the config
# Alloy reads with the config alloy-config.ts builds. The chart runs Helm's tpl over the config, so
# a Go template in it, such as a stage.template of the atc security pipeline, that reaches tpl
# unescaped fails the render or comes out changed. A second case checks the DaemonSet's init
# container, which seeds Alloy's read positions, against the volumes the Alloy container mounts.
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
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-files-equal.sh"

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

# setup_test <tree>: the pinned chart's archive and the values as the repo builds them
setup_test() {
  local tree="$1"
  mkdir "$tree/chart"
  (cd "$repo" && TREE="$tree" bun -e "
    import { alloyChart } from './infra/observability/alloy-chart.ts';
    import { alloyValues } from './infra/observability/alloy-values.ts';
    const tree = process.env.TREE ?? '';
    await Bun.write(tree + '/chart.json', JSON.stringify(alloyChart));
    await Bun.write(tree + '/values.json', JSON.stringify(alloyValues));
  ")
  docker pull -q "$helm_image" > /dev/null
  run_helm "$tree" pull "$(jq -r .chart "$tree/chart.json")" \
    --repo "$(jq -r .repositoryOpts.repo "$tree/chart.json")" \
    --version "$(jq -r .version "$tree/chart.json")" -d /work/chart
  (cd "$tree/chart" && echo "$chart_digest  $(jq -r '.chart + "-" + .version' "$tree/chart.json").tgz" | sha256sum -c --quiet)
}

it_renders_the_configmap_with_the_config_the_repo_builds_its_go_templates_intact() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json --show-only templates/configmap.yaml > "$tree/configmap.yaml" 2> "$tree/err" || status=$?

  assert_equals 0 "$status" 'helm template exit'
  diff /dev/null "$tree/err"
  # the chart writes the config as a |- block, which drops the final newline
  (cd "$repo" && TREE="$tree" bun -e "
    import { alloyConfig } from './infra/observability/alloy-config.ts';
    const tree = process.env.TREE ?? '';
    const configMap = Bun.YAML.parse(await Bun.file(tree + '/configmap.yaml').text());
    await Bun.write(tree + '/rendered.alloy', configMap.data['config.alloy'] + '\n');
    await Bun.write(tree + '/built.alloy', alloyConfig);
  ")
  assert_files_equal "$tree/built.alloy" "$tree/rendered.alloy"
  grep -F 'template = "{{ if eq .kind \"suppressed\" }}none{{ else if eq .kind \"other\" }}other{{ else }}{{ .outcome }}{{ end }}"' "$tree/rendered.alloy" > /dev/null
}

it_renders_the_seed_init_container_on_the_alloy_containers_image_over_the_nodes_log_and_storage_directories() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  run_helm "$tree" template alloy "/work/chart/$(ls "$tree/chart")" --namespace observability \
    -f /work/values.json --show-only templates/controllers/daemonset.yaml > "$tree/daemonset.yaml" 2> "$tree/err" || status=$?

  assert_equals 0 "$status" 'helm template exit'
  diff /dev/null "$tree/err"
  # each line: the init container's mount, the host path of the pod volume it names, and whether
  # the Alloy container mounts that volume at the same path
  (cd "$repo" && TREE="$tree" bun -e "
    const tree = process.env.TREE ?? '';
    const pod = Bun.YAML.parse(await Bun.file(tree + '/daemonset.yaml').text()).spec.template.spec;
    const [init] = pod.initContainers;
    const alloy = pod.containers.find((container) => container.name === 'alloy');
    const lines = [init.name + ' ' + (init.image === alloy.image ? 'on the alloy image' : init.image)];
    for (const mount of init.volumeMounts) {
      const volume = pod.volumes.find((candidate) => candidate.name === mount.name);
      const shared = alloy.volumeMounts.some((other) => other.name === mount.name && other.mountPath === mount.mountPath);
      lines.push([mount.name, mount.mountPath, mount.readOnly ? 'ro' : 'rw', volume?.hostPath?.path, shared ? 'shared' : 'init only'].join(' '));
    }
    await Bun.write(tree + '/init.txt', lines.join('\n') + '\n');
  ")
  diff - "$tree/init.txt" << 'EOF'
seed-pod-log-positions on the alloy image
varlog /var/log ro /var/log shared
storage /var/lib/alloy rw /var/lib/alloy shared
EOF
}

run_cases
