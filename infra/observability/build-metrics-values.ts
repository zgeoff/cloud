import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import { lokiURL } from './loki-url.ts';

// the textfile collector reads metrics that host timers write; node-exporter sees the host root
// at /host/root
const nodeExporterArgs = [
  '--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)',
  '--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|erofs)$',
  `--collector.textfile.directory=/host/root${topology.nodeExporter.textfileDir}`,
];

// Grafana idles near 240Mi, and each query and each plugin backend it installs at start adds
// to that: at a 256Mi limit, Explore got it OOM-killed.
const grafanaResources = { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '768Mi' } };

// Prometheus sets GOMEMLIMIT to 0.9 of its limit, and the rest holds the TSDB's mmapped chunks: at
// 512Mi the heap reached 430MB and the kernel reclaimed those pages without pause. The headroom
// covers node-exporter's ZFS series, which grow with each imp's datasets.
const prometheusResources = {
  requests: { cpu: '100m', memory: '512Mi' },
  limits: { memory: '1Gi' },
};

// k3s's kubelet /metrics serves the whole k3s process, so the kubelet job drops the control plane's
// series, which the chart's rules and dashboards read from the apiserver job. The first rule is
// the chart's default, which this list replaces.
const kubeletMetricRelabelings = [
  {
    action: 'drop',
    sourceLabels: ['__name__', 'le'],
    regex:
      '(csi_operations|storage_operation_duration)_seconds_bucket;(0.25|2.5|15|25|120|600)(\\.0)?',
  },
  {
    action: 'drop',
    sourceLabels: ['__name__'],
    regex: '(apiserver|etcd|workqueue|scheduler|kine)_.+',
  },
];

interface GrafanaInputs {
  readonly password: Output<string>;
  readonly nodePort: number;
}

export function buildMetricsValues(grafana: GrafanaInputs): Record<string, unknown> {
  return {
    // a per-target TargetDown rule replaces the chart's ratio-based one
    defaultRules: { disabled: { TargetDown: true } },

    // k3s runs these inside the k3s binary, whose metrics the apiserver and kubelet jobs scrape
    kubeEtcd: { enabled: false },
    kubeControllerManager: { enabled: false },
    kubeScheduler: { enabled: false },
    kubeProxy: { enabled: false },
    kubelet: { serviceMonitor: { metricRelabelings: kubeletMetricRelabelings } },

    // a Helm hook Job makes the webhook's TLS secret, and Pulumi does not run Helm
    // hooks, so the operator waits on that secret forever. One node, one operator:
    // the webhook only validates rules, so go without it.
    prometheusOperator: { admissionWebhooks: { enabled: false }, tls: { enabled: false } },
    prometheus: {
      prometheusSpec: {
        retention: '30d',
        retentionSize: '8GB',
        resources: prometheusResources,

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
      additionalDataSources: [{ name: 'Loki', type: 'loki', url: lokiURL, access: 'proxy' }],

      // no Alertmanager datasource: Grafana does no alerting here; deleteDatasources removes the
      // copy Grafana provisioned while Alertmanager was off
      sidecar: { datasources: { alertmanager: { enabled: false } } },
      deleteDatasources: [{ name: 'Alertmanager', orgId: 1 }],
    },
  };
}
