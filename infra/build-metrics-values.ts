import type { Output } from '@pulumi/pulumi';

// the chart's own args plus the textfile collector, which reads metrics that host timers
// write (impd local health, #29); node-exporter sees the host root at /host/root
const nodeExporterArgs = [
  '--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)',
  '--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|erofs)$',
  '--collector.textfile.directory=/host/root/var/lib/node-exporter/textfile',
];

// Grafana idles near 240Mi, and each query and each plugin backend it installs at start adds
// to that: at a 256Mi limit, Explore got it OOM-killed.
const grafanaResources = { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '768Mi' } };

// Grafana's admin password, and the node port it serves on
interface GrafanaInputs {
  readonly password: Output<string>;
  readonly nodePort: number;
}

// the chart's values but Alertmanager's, which buildAlertmanagerValues gives
export function buildMetricsValues(grafana: GrafanaInputs): Record<string, unknown> {
  return {
    // buildAlertRules has a per-target TargetDown in place of the chart's ratio-based one
    defaultRules: { disabled: { TargetDown: true } },

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

        // pick up every ServiceMonitor, PodMonitor and PrometheusRule, not only the chart's own
        serviceMonitorSelectorNilUsesHelmValues: false,
        podMonitorSelectorNilUsesHelmValues: false,
        ruleSelectorNilUsesHelmValues: false,
        storageSpec: {
          volumeClaimTemplate: {
            spec: { accessModes: ['ReadWriteOnce'], resources: { requests: { storage: '10Gi' } } },
          },
        },
      },
    },

    'prometheus-node-exporter': { extraArgs: nodeExporterArgs },
    grafana: {
      adminPassword: grafana.password,
      service: { type: 'NodePort', nodePort: grafana.nodePort },
      resources: grafanaResources,
      additionalDataSources: [
        { name: 'Loki', type: 'loki', url: 'http://loki.observability.svc:3100', access: 'proxy' },
      ],

      // no Alertmanager datasource: Grafana does no alerting here, and alerts show in
      // Prometheus and Alertmanager themselves (#28, #29); deleteDatasources removes the
      // copy Grafana provisioned while Alertmanager was off
      sidecar: { datasources: { alertmanager: { enabled: false } } },
      deleteDatasources: [{ name: 'Alertmanager', orgId: 1 }],
    },
  };
}
