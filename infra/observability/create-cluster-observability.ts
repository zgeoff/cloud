// the observability stack wires its charts, monitors and dashboards here, one import each
/* oxlint-disable import/max-dependencies */
import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { RandomPassword } from '@pulumi/random';
import { topology } from '@zgeoff/cloud-topology';
import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { alloyValues } from './alloy-values.ts';
import { createDashboards } from './create-dashboards.ts';
import { createMetrics } from './create-metrics.ts';
import { createMonitors } from './create-monitors.ts';
import { lokiValues } from './loki-values.ts';
import { observabilityNamespace } from './observability-namespace.ts';

// Grafana on the host's tailnet address only: the NixOS firewall trusts tailscale0
// and opens no public port, so http://geoffcloud:<grafanaNodePort> works from the tailnet alone.
const grafanaNodePort = topology.k3s.grafanaNodePort;

interface ClusterObservabilityOutputs {
  readonly grafanaURL: string;
  readonly grafanaAdminPassword: Output<string>;
}

// Prometheus, Alertmanager, Grafana, Loki, Alloy on one node (~1 GiB, #8); 30-day retention.
// Alertmanager reaches Discord only with alertWebhookURL (#29). atcDaemons adds a TCP probe
// plus alert per atc daemon, set only with the gateway.
export function createClusterObservability(
  cluster: Provider,
  alertWebhookURL: string | undefined,
  atcDaemons: readonly ATCDaemonEndpoint[] | undefined,
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
  createMonitors(ns, atcDaemons, { provider: cluster, dependsOn: [metrics] });
  createDashboards(ns, cluster);

  return {
    grafanaURL: `http://geoffcloud:${grafanaNodePort}`,
    grafanaAdminPassword: adminPassword.result,
  };
}

// Alloy ships pod logs and the host journal to Loki (alloyValues)
function createLogShipper(ns: Namespace, dependsOn: Chart[], cluster: Provider): Chart {
  return new Chart(
    'alloy',
    {
      namespace: ns.metadata.name,
      chart: 'alloy',
      version: '1.13.0',
      repositoryOpts: { repo: 'https://grafana.github.io/helm-charts' },
      values: alloyValues,
    },
    { provider: cluster, dependsOn },
  );
}
