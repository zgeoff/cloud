import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { RandomPassword } from '@pulumi/random';
import { topology } from '@zgeoff/cloud-topology';
import { alloyChart } from './alloy-chart.ts';
import { alloyValues } from './alloy-values.ts';
import type { AlertRuleInputs } from './build-alert-rules.ts';
import { createDashboards } from './create-dashboards.ts';
import { createMetrics } from './create-metrics.ts';
import { createMonitors } from './create-monitors.ts';
import { lokiValues } from './loki-values.ts';
import { makeDeleteBeforeReplaceTransform } from './make-delete-before-replace-transform.ts';
import { observabilityNamespace } from './observability-namespace.ts';

// Grafana on the host's tailnet address only: the NixOS firewall trusts tailscale0
// and opens no public port, so http://geoffcloud:<grafanaNodePort> works from the tailnet alone.
const grafanaNodePort = topology.k3s.grafanaNodePort;

interface ClusterObservabilityOutputs {
  readonly grafanaURL: string;
  readonly grafanaAdminPassword: Output<string>;
}

// Prometheus, Alertmanager, Grafana, Loki, Alloy on one node (~1 GiB, #8); 30-day retention.
// Alertmanager reaches Discord only with alertWebhookURL (#29). monitors adds the probes and
// alerts for the atc daemons and nixie, each set only with its workload.
export function createClusterObservability(
  cluster: Provider,
  alertWebhookURL: string | undefined,
  monitors: AlertRuleInputs,
): ClusterObservabilityOutputs {
  const opts = { provider: cluster };

  const ns = new Namespace('observability', { metadata: { name: observabilityNamespace } }, opts);
  const adminPassword = new RandomPassword('grafana-admin', { length: 32, special: false });

  const metrics = createMetrics(
    ns,
    { grafanaPassword: adminPassword.result, grafanaNodePort, alertWebhookURL },
    cluster,
  );

  const logs = new Chart(
    'loki',
    {
      namespace: ns.metadata.name,
      chart: 'loki',
      version: '7.3.0',
      repositoryOpts: { repo: 'https://grafana.github.io/helm-charts' },
      values: lokiValues,
    },
    opts,
  );

  createLogShipper(ns, [logs, metrics], cluster);
  createMonitors(ns, monitors, { provider: cluster, dependsOn: [metrics] });
  createDashboards(ns, cluster);

  return {
    grafanaURL: `http://geoffcloud:${grafanaNodePort}`,
    grafanaAdminPassword: adminPassword.result,
  };
}

// Alloy ships pod logs and the host journal to Loki (alloyValues). A change to its config replaces
// the chart's fixed-name ConfigMap, so the old one goes first.
function createLogShipper(ns: Namespace, dependsOn: Chart[], cluster: Provider): Chart {
  return new Chart(
    'alloy',
    { namespace: ns.metadata.name, ...alloyChart, values: alloyValues },
    { provider: cluster, dependsOn, transforms: [makeDeleteBeforeReplaceTransform(cluster)] },
  );
}
