import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMetricsValues } from './build-metrics-values.ts';

test("it disables the chart's TargetDown, drops the kubelet's copy of the control plane's series, picks up every monitor and rule, and serves Grafana on its node port", () => {
  const password = output('grafana-admin-password');

  expect(buildMetricsValues({ password, nodePort: 30_300 })).toStrictEqual({
    defaultRules: { disabled: { TargetDown: true } },
    kubeEtcd: { enabled: false },
    kubeControllerManager: { enabled: false },
    kubeScheduler: { enabled: false },
    kubeProxy: { enabled: false },
    kubelet: {
      serviceMonitor: {
        metricRelabelings: [
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
        ],
      },
    },
    prometheusOperator: { admissionWebhooks: { enabled: false }, tls: { enabled: false } },
    prometheus: {
      prometheusSpec: {
        retention: '30d',
        retentionSize: '8GB',
        resources: { requests: { cpu: '100m', memory: '512Mi' }, limits: { memory: '1Gi' } },
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
    'prometheus-node-exporter': {
      extraArgs: [
        '--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)',
        '--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|erofs)$',
        '--collector.textfile.directory=/host/root/var/lib/node-exporter/textfile',
      ],
    },
    grafana: {
      adminPassword: password,
      service: { type: 'NodePort', nodePort: 30_300 },
      resources: { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '768Mi' } },
      additionalDataSources: [
        { name: 'Loki', type: 'loki', url: 'http://loki.observability.svc:3100', access: 'proxy' },
      ],
      sidecar: { datasources: { alertmanager: { enabled: false } } },
      deleteDatasources: [{ name: 'Alertmanager', orgId: 1 }],
    },
  });
});
