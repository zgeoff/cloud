import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import { buildAlertRules } from './build-alert-rules.ts';

// buildAlertRules' groups as a PrometheusRule (#29). Prometheus picks up every
// PrometheusRule (ruleSelectorNilUsesHelmValues: false in observability.ts); the chart
// brings the CRD, so opts makes this wait for it. atcDaemonAddress, set only with the
// atc gateway, adds ATCDaemonUnreachable.
export function createAlertRules(
  ns: Namespace,
  atcDaemonAddress: string | undefined,
  opts: CustomResourceOptions,
): CustomResource {
  return new CustomResource(
    'geoff-cloud-alerts',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PrometheusRule',
      metadata: { name: 'geoff-cloud-alerts', namespace: ns.metadata.name },
      spec: { groups: buildAlertRules({ atcDaemonAddress }) },
    },
    opts,
  );
}
