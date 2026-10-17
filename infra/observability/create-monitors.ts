import { CustomResource } from '@pulumi/kubernetes/apiextensions';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import type { CustomResourceOptions } from '@pulumi/pulumi';
import { cloudflaredNames } from '../ingress/index.ts';
import type { AlertRuleInputs } from './build-alert-rules.ts';
import { createAlertRules } from './create-alert-rules.ts';
import { createATCDaemonProbe } from './create-atc-daemon-probe.ts';
import { createImpHealthProbe } from './create-imp-health-probe.ts';
import { createNixieTurnsProbe } from './create-nixie-turns-probe.ts';

// Beyond the stack's own targets: cloudflared, geoff.cloud's alert rules, imp's /health, only
// with the gateway a TCP probe per atc daemon, and only with nixie a probe of its readiness report.
// opts carries the cluster and the stack dependency that brings the CRDs.
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
    createNixieTurnsProbe(ns, inputs.nixieReadinessURL, opts);
  }
}

// cloudflared serves Prometheus metrics on its metrics port, with the names ingress gives it
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
