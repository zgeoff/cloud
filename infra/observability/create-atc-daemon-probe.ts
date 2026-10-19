import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import type { ATCDaemonEndpoint } from '../inputs/index.ts';
import { blackboxChart } from './blackbox-chart.ts';
import { buildATCDaemonProbeValues } from './build-atc-daemon-probe-values.ts';

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
