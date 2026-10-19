import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import type { AlertRuleInputs } from './build-alert-rules.ts';
import { buildAlertRules } from './build-alert-rules.ts';

export function createAlertRules(
  ns: Namespace,
  inputs: AlertRuleInputs,
  opts: CustomResourceOptions,
): CustomResource {
  return new CustomResource(
    'geoff-cloud-alerts',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PrometheusRule',
      metadata: { name: 'geoff-cloud-alerts', namespace: ns.metadata.name },
      spec: { groups: buildAlertRules(inputs) },
    },

    // The chart brings the CRD, so opts waits for it.
    opts,
  );
}
