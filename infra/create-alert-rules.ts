import type { Provider } from '@pulumi/kubernetes';
import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { Chart } from '@pulumi/kubernetes/helm/v4';
import { buildAlertRules } from './build-alert-rules.ts';

// buildAlertRules' groups as a PrometheusRule (#29). Prometheus picks up every
// PrometheusRule (ruleSelectorNilUsesHelmValues: false in observability.ts); the chart
// brings the CRD, so this waits for it.
export function createAlertRules(ns: Namespace, metrics: Chart, cluster: Provider): CustomResource {
  return new CustomResource(
    'geoff-cloud-alerts',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PrometheusRule',
      metadata: { name: 'geoff-cloud-alerts', namespace: ns.metadata.name },
      spec: { groups: buildAlertRules() },
    },
    { provider: cluster, dependsOn: [metrics] },
  );
}
