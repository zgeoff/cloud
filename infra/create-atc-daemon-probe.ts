import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';
import { buildATCDaemonProbeValues } from './build-atc-daemon-probe-values.ts';

// Blackbox TCP probe of each atc daemon every 30s from a pod, down the gateway's own path
// (host cloud_host table admits cni0 to geoffcloud's daemon; otherwise the tailnet), one
// ServiceMonitor per daemon. ATCDaemonUnreachable alerts on the result (build-alert-rules.ts).
export function createATCDaemonProbe(
  ns: Namespace,
  daemons: readonly ATCDaemonEndpoint[],
  opts: ComponentResourceOptions,
): Chart {
  return new Chart(
    'atc-daemon-probe',
    {
      namespace: ns.metadata.name,
      chart: 'prometheus-blackbox-exporter',
      version: '11.19.1',
      repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
      values: buildATCDaemonProbeValues(daemons),
    },
    opts,
  );
}
