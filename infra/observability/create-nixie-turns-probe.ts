import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { blackboxChart } from './blackbox-chart.ts';
import { buildNixieTurnsProbeValues } from './build-nixie-turns-probe-values.ts';

// Blackbox fetch of nixie's readiness report every 30s through its Service, alerting as
// NixieTurnsFailing. Its own chart keeps the other probes untouched; the report needs no
// credentials, so the probe has none.
export function createNixieTurnsProbe(
  ns: Namespace,
  readinessURL: string,
  opts: ComponentResourceOptions,
): Chart {
  return new Chart(
    'nixie-turns-probe',
    {
      namespace: ns.metadata.name,
      ...blackboxChart,
      values: buildNixieTurnsProbeValues(readinessURL),
    },
    opts,
  );
}
