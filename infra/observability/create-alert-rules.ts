import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import type { AlertRuleInputs } from './build-alert-rules.ts';
import { buildAlertRules } from './build-alert-rules.ts';
import { buildATCSignInRules } from './build-atc-sign-in-rules.ts';

// buildAlertRules' groups and the atc sign-in group, which no event fires without a gateway, as a
// PrometheusRule (#29) picked up via ruleSelectorNilUsesHelmValues. The chart brings the CRD, so
// opts waits for it; inputs add ATCDaemonUnreachable per daemon and NixieTurnsFailing.
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
      spec: { groups: [...buildAlertRules(inputs), buildATCSignInRules()] },
    },
    opts,
  );
}
