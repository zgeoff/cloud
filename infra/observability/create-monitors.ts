import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { createAlertRules } from './create-alert-rules.ts';
import { createATCDaemonProbe } from './create-atc-daemon-probe.ts';
import { createImpHealthProbe } from './create-imp-health-probe.ts';

// Beyond the stack's own targets: cloudflared, geoff.cloud's alert rules, imp's /health, and,
// only with the gateway, a TCP probe per atc daemon. opts carries the cluster and the stack
// dependency that brings the CRDs.
export function createMonitors(
  ns: Namespace,
  atcDaemons: readonly ATCDaemonEndpoint[] | undefined,
  opts: CustomResourceOptions,
): void {
  createCloudflaredMonitor(ns, opts);
  createAlertRules(ns, atcDaemons, opts);
  createImpHealthProbe(ns, opts);

  if (atcDaemons !== undefined) {
    createATCDaemonProbe(ns, atcDaemons, opts);
  }
}

// cloudflared serves Prometheus metrics on its `metrics` port (ingress/create-cloudflared.ts)
function createCloudflaredMonitor(ns: Namespace, opts: CustomResourceOptions): CustomResource {
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
    opts,
  );
}
