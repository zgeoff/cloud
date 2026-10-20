import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import type { ComponentResourceOptions } from '@pulumi/pulumi';
import { createEgressAllow } from '../shared/create-egress-allow.ts';
import { egressAllows } from '../shared/egress-allows.ts';
import { blackboxChart } from './blackbox-chart.ts';
import { impHealthProbeValues } from './imp-health-probe-values.ts';

export function createImpHealthProbe(ns: Namespace, opts: ComponentResourceOptions): Chart {
  createEgressAllow(egressAllows.impHealthProbe, ns.metadata.name, opts);

  return new Chart(
    'imp-health-probe',
    {
      namespace: ns.metadata.name,
      ...blackboxChart,
      values: impHealthProbeValues,
    },
    opts,
  );
}
