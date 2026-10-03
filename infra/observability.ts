import type { Provider } from '@pulumi/kubernetes';
import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { Output } from '@pulumi/pulumi';
import { RandomPassword } from '@pulumi/random';
import { createDashboards } from './create-dashboards.ts';

// Grafana on the host's tailnet address only: the NixOS firewall trusts tailscale0
// and opens no public port, so http://geoffcloud:30300 works from the tailnet alone.
const grafanaNodePort = 30_300;

interface ObservabilityOutputs {
  readonly logShipper: Chart;
  readonly grafanaURL: string;
  readonly grafanaAdminPassword: Output<string>;
}

// Prometheus, Grafana, Loki and Alloy, sized for about 1 GiB on one node (#8).
// Retention is 30 days for metrics and logs.
export function createObservability(cluster: Provider): ObservabilityOutputs {
  const opts = { provider: cluster };

  const ns = new Namespace('observability', { metadata: { name: 'observability' } }, opts);
  const adminPassword = new RandomPassword('grafana-admin', { length: 32, special: false });

  const metrics = new Chart(
    'kube-prometheus-stack',
    {
      namespace: ns.metadata.name,
      chart: 'kube-prometheus-stack',
      version: '91.8.2',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: buildMetricsValues(adminPassword.result),
    },
    opts,
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

  createCloudflaredMonitor(ns, metrics, cluster);
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

// cloudflared serves Prometheus metrics on its `metrics` port (cluster-workloads.ts)
function createCloudflaredMonitor(
  ns: Namespace,
  metrics: Chart,
  cluster: Provider,
): CustomResource {
  return new CustomResource(
    'cloudflared',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PodMonitor',
      metadata: { name: 'cloudflared', namespace: ns.metadata.name },
      spec: {
        namespaceSelector: { matchNames: ['ingress'] },
        selector: { matchLabels: { app: 'cloudflared' } },
        podMetricsEndpoints: [{ port: 'metrics' }],
      },
    },
    { provider: cluster, dependsOn: [metrics] },
  );
}

function buildMetricsValues(grafanaPassword: Output<string>): Record<string, unknown> {
  return {
    alertmanager: { enabled: false },

    // k3s runs these inside the k3s binary; there is nothing separate to scrape
    kubeEtcd: { enabled: false },
    kubeControllerManager: { enabled: false },
    kubeScheduler: { enabled: false },
    kubeProxy: { enabled: false },

    // a Helm hook Job makes the webhook's TLS secret, and Pulumi does not run Helm
    // hooks, so the operator waits on that secret forever. One node, one operator:
    // the webhook only validates rules, so go without it.
    prometheusOperator: { admissionWebhooks: { enabled: false }, tls: { enabled: false } },
    prometheus: {
      prometheusSpec: {
        retention: '30d',
        retentionSize: '8GB',
        resources: { requests: { cpu: '100m', memory: '256Mi' }, limits: { memory: '512Mi' } },

        // pick up every ServiceMonitor and PodMonitor, not only the chart's own
        serviceMonitorSelectorNilUsesHelmValues: false,
        podMonitorSelectorNilUsesHelmValues: false,
        storageSpec: {
          volumeClaimTemplate: {
            spec: { accessModes: ['ReadWriteOnce'], resources: { requests: { storage: '10Gi' } } },
          },
        },
      },
    },
    grafana: {
      adminPassword: grafanaPassword,
      service: { type: 'NodePort', nodePort: grafanaNodePort },
      resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
      additionalDataSources: [
        { name: 'Loki', type: 'loki', url: 'http://loki.observability.svc:3100', access: 'proxy' },
      ],
    },
  };
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

// Alloy as a DaemonSet: tail every pod's logs and the host's journal, and push them to Loki
const alloyValues = {
  alloy: {
    configMap: {
      content: `
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.process.pods.receiver]
}

// the atc gateway's OAuth approval lines stay in kubectl logs only, never in Loki
loki.process "pods" {
  stage.match {
    selector = "{namespace=\\"atc\\", container=\\"atc-gateway\\"} |~ \\"^atc-approval\\""
    action   = "drop"
  }
  forward_to = [loki.write.default.receiver]
}

// the host's journal: impd (imp-host logs to journald), k3s, tailscaled and the rest
// of the host, which no pod log covers
loki.source.journal "host" {
  path          = "/var/log/journal"
  // Loki rejects entries more than an hour behind a stream's newest; a restart
  // re-reads from max_age, since the read position is not persisted
  max_age       = "1h"
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "journal" }
  forward_to    = [loki.write.default.receiver]
}

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
}

loki.write "default" {
  endpoint {
    url = "http://loki.observability.svc:3100/loki/api/v1/push"
  }
}
`,
    },

    // /var/log from the host, read-only, for the journal
    mounts: { varlog: true },
    resources: { requests: { cpu: '20m', memory: '64Mi' }, limits: { memory: '192Mi' } },
  },
};
