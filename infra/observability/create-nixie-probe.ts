import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { blackboxChart } from './blackbox-chart.ts';
import { buildNixieProbeValues } from './build-nixie-probe-values.ts';

export function createNixieProbe(
  ns: Namespace,
  readinessURL: string,
  opts: ComponentResourceOptions,
): Chart {
  // a new release name would replace the release
  return new Chart(
    'nixie-turns-probe',
    {
      namespace: ns.metadata.name,
      ...blackboxChart,
      values: buildNixieProbeValues(readinessURL),
    },
    opts,
  );
}
