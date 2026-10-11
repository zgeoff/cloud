import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { impHealthProbeValues } from './imp-health-probe-values.ts';

// Blackbox fetch of imp's /health every 30s over the clients' path (public DNS, host tailnet
// node, tag:cloud to imp 443; see tailnet-policy.ts), alerting as ImpHealthUnreachable. Its own
// chart keeps the atc probe untouched; /health needs no credentials, so the probe has none.
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
