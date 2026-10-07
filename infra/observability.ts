import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { RandomPassword } from '@pulumi/random';
import { alloyValues } from './alloy-values.ts';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { createDashboards } from './create-dashboards.ts';
import { createMetrics } from './create-metrics.ts';
import { createMonitors } from './create-monitors.ts';

// Grafana on the host's tailnet address only: the NixOS firewall trusts tailscale0
// and opens no public port, so http://geoffcloud:30300 works from the tailnet alone.
const grafanaNodePort = 30_300;

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

// Prometheus, Alertmanager, Grafana, Loki and Alloy, sized for about 1 GiB on one node
// (#8). Retention is 30 days for metrics and logs. Alertmanager delivers to Discord only
// when alertWebhookURL is set (#29); otherwise it sends nothing. atcDaemons, set only
// with the atc gateway, adds a TCP probe of each of atc's daemons and its alert.
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
