import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { blackboxChart } from './blackbox-chart.ts';
import { buildATCDaemonProbeValues } from './build-atc-daemon-probe-values.ts';

// Blackbox TCP probe of each atc daemon every 30s from a pod, down the gateway's own path (host cloud_host admits
// cni0 from the pod CIDR to geoffcloud's daemon; otherwise the tailnet). The chart's ServiceMonitor carries the probe for
// Prometheus (create-cluster-observability.ts); opts brings the cluster plus the stack dep owning the CRDs, and ATCDaemonUnreachable alerts on it.
export function createATCDaemonProbe(
  ns: Namespace,
  daemons: readonly ATCDaemonEndpoint[],
  opts: ComponentResourceOptions,
): Chart {
  return new Chart(
    'atc-daemon-probe',
    {
      namespace: ns.metadata.name,
      ...blackboxChart,
      values: buildATCDaemonProbeValues(daemons),
    },
    opts,
  );
}
