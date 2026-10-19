import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { blackboxChart } from './blackbox-chart.ts';
import { buildNixieProbeValues } from './build-nixie-probe-values.ts';

// Blackbox fetches of nixie's readiness report every 30s through its Service, alerting as
// NixieTurnsFailing and NixieDegraded. Its own chart keeps the other probes untouched, and its
// release keeps the name nixie-turns-probe, because a new name would replace the release.
export function createNixieProbe(
  ns: Namespace,
  readinessURL: string,
  opts: ComponentResourceOptions,
): Chart {
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
