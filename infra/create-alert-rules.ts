import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { buildAlertRules } from './build-alert-rules.ts';

// buildAlertRules' groups as a PrometheusRule (#29), picked up via ruleSelectorNilUsesHelmValues.
// The chart brings the CRD, so opts waits for it; atcDaemons adds ATCDaemonUnreachable per daemon.
export function createAlertRules(
  ns: Namespace,
  atcDaemons: readonly ATCDaemonEndpoint[] | undefined,
  opts: CustomResourceOptions,
): CustomResource {
  return new CustomResource(
    'geoff-cloud-alerts',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PrometheusRule',
      metadata: { name: 'geoff-cloud-alerts', namespace: ns.metadata.name },
      spec: { groups: buildAlertRules({ atcDaemons }) },
    },
    opts,
  );
}
