import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import { cloudflaredNames } from '../ingress/index.ts';
import { nixieGitSyncNames } from '../shared/nixie-git-sync-names.ts';
import type { AlertRuleInputs } from './build-alert-rules.ts';
import { createAlertRules } from './create-alert-rules.ts';
import { createATCDaemonProbe } from './create-atc-daemon-probe.ts';
import { createImpHealthProbe } from './create-imp-health-probe.ts';
import { createNixieProbe } from './create-nixie-probe.ts';

export function createMonitors(
  ns: Namespace,
  inputs: AlertRuleInputs,
  opts: CustomResourceOptions,
): void {
  createCloudflaredMonitor(ns, opts);
  createAlertRules(ns, inputs, opts);
  createImpHealthProbe(ns, opts);

  if (inputs.atcDaemons !== undefined) {
    createATCDaemonProbe(ns, inputs.atcDaemons, opts);
  }

  if (inputs.nixieReadinessURL !== undefined) {
    createNixieProbe(ns, inputs.nixieReadinessURL, opts);
    createNixieGitSyncMonitor(ns, opts);
  }
}

function createCloudflaredMonitor(ns: Namespace, opts: CustomResourceOptions): CustomResource {
  return new CustomResource(
    'cloudflared',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PodMonitor',
      metadata: { name: 'cloudflared', namespace: ns.metadata.name },
      spec: {
        namespaceSelector: { matchNames: [cloudflaredNames.namespace] },
        selector: { matchLabels: cloudflaredNames.labels },
        podMetricsEndpoints: [{ port: cloudflaredNames.metricsPort }],
      },
    },
    opts,
  );
}

function createNixieGitSyncMonitor(ns: Namespace, opts: CustomResourceOptions): CustomResource {
  return new CustomResource(
    'nixie-git-sync',
    {
      apiVersion: 'monitoring.coreos.com/v1',
      kind: 'PodMonitor',
      metadata: { name: 'nixie-git-sync', namespace: ns.metadata.name },
      spec: {
        namespaceSelector: { matchNames: [nixieGitSyncNames.namespace] },
        selector: { matchLabels: nixieGitSyncNames.labels },
        podMetricsEndpoints: [{ port: nixieGitSyncNames.httpPort }],
      },
    },
    opts,
  );
}
