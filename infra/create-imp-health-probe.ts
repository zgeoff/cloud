import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { impHealthProbeValues } from './imp-health-probe-values.ts';

// The blackbox exporter, fetching imp's /health from a pod every 30s over the path
// clients take (#29): public DNS gives imp's tailnet address, the pod's connection leaves
// through the host's tailnet node, and the tailnet policy lets tag:cloud reach imp's node
// on 443 only (tailnet-policy.ts). ImpHealthUnreachable (build-alert-rules.ts) alerts on
// the result. A chart of its own, so the atc daemon probe stays as it is. /health needs no
// credentials, so the probe carries none.
export function createImpHealthProbe(ns: Namespace, opts: ComponentResourceOptions): Chart {
  return new Chart(
    'imp-health-probe',
    {
      namespace: ns.metadata.name,
      chart: 'prometheus-blackbox-exporter',
      version: '11.19.1',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: impHealthProbeValues,
    },
    opts,
  );
}
