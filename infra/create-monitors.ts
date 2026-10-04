import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { createAlertRules } from './create-alert-rules.ts';
import { createATCDaemonProbe } from './create-atc-daemon-probe.ts';
import { createImpHealthProbe } from './create-imp-health-probe.ts';

// What Prometheus watches beyond kube-prometheus-stack's own targets: cloudflared,
// geoff.cloud's alert rules, imp's /health over the tailnet and, only with the atc gateway, a TCP probe of each of
// atc's daemons. opts carries the cluster and the dependency on the stack, which brings the
// CRDs.
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

// cloudflared serves Prometheus metrics on its `metrics` port (cluster-workloads.ts)
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
