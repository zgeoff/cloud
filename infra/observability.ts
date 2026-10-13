// the observability stack wires its charts, monitors and dashboards here, one import each
/* oxlint-disable import/max-dependencies */
import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { RandomPassword } from '@pulumi/random';
import { topology } from '@zgeoff/cloud-topology';
import { alloyValues } from './alloy-values.ts';
import { createDashboards } from './create-dashboards.ts';
import { createMetrics } from './create-metrics.ts';
import { createMonitors } from './create-monitors.ts';
import type { ATCDaemonEndpoint } from './inputs/types.ts';

// Grafana on the host's tailnet address only: the NixOS firewall trusts tailscale0
// and opens no public port, so http://geoffcloud:<grafanaNodePort> works from the tailnet alone.
const grafanaNodePort = topology.k3s.grafanaNodePort;

export interface ObservabilityOutputs {
  readonly logShipper: Chart;
  readonly grafanaURL: string;
  readonly grafanaAdminPassword: Output<string>;
}

const lokiValues = {
  deploymentMode: 'SingleBinary',
  loki: {
    auth_enabled: false,
    commonConfig: { replication_factor: 1 },
    storage: { type: 'filesystem' },
    schemaConfig: {
      configs: [
        {
          from: '2026-10-01',
          store: 'tsdb',
          object_store: 'filesystem',
          schema: 'v13',
          index: { prefix: 'index_', period: '24h' },
        },
      ],
    },
    limits_config: { retention_period: '720h' },
    compactor: { retention_enabled: true, delete_request_store: 'filesystem' },
  },
  singleBinary: {
    replicas: 1,
    persistence: { size: '20Gi' },
    resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '384Mi' } },
  },
  read: { replicas: 0 },
  write: { replicas: 0 },
  backend: { replicas: 0 },
  chunksCache: { enabled: false },
  resultsCache: { enabled: false },
  gateway: { enabled: false },
  lokiCanary: { enabled: false },
  test: { enabled: false },
};

// Prometheus, Alertmanager, Grafana, Loki, Alloy on one node (~1 GiB, #8); 30-day retention.
// Alertmanager reaches Discord only with alertWebhookURL (#29). atcDaemons adds a TCP probe
// plus alert per atc daemon, set only with the gateway.
export function createObservability(
  cluster: Provider,
  alertWebhookURL: string | undefined,
  atcDaemons: readonly ATCDaemonEndpoint[] | undefined,
): ObservabilityOutputs {
  const opts = { provider: cluster };

  const ns = new Namespace('observability', { metadata: { name: 'observability' } }, opts);
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

  const shipper = createLogShipper(ns, [logs, metrics], cluster);

  createMonitors(ns, atcDaemons, { provider: cluster, dependsOn: [metrics] });
  createDashboards(ns, cluster);

  return {
    logShipper: shipper,
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
