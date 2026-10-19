import type { ChartArgs } from '@pulumi/kubernetes/helm/v4';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { buildNixieIngressValues } from './build-nixie-ingress-values.ts';

export interface NixieIngressChartInputs {
  // the namespace the controller runs in: a hostPort keeps it out of Pod Security's baseline
  readonly controllerNamespace: string;

  // the one namespace whose Ingress objects the controller serves
  readonly routesNamespace: string;
  readonly ingressClass: string;
}

// Traefik's release: it runs in its own namespace and serves the Ingress objects of nixie's
export function buildNixieIngressChartArgs(inputs: NixieIngressChartInputs): ChartArgs {
  return {
    namespace: inputs.controllerNamespace,
    chart: 'traefik',
    version: '41.6.0',
    repositoryOpts: { repo: 'https://traefik.github.io/charts' },

    // Ingress objects only: no Traefik, Hub or Gateway CRDs in the cluster
    skipCrds: true,
    values: buildNixieIngressValues({
      httpsPort: geoffcloudNode.httpsPort,
      endpointIP: geoffcloudNode.ip,
      ingressClass: inputs.ingressClass,
      namespace: inputs.routesNamespace,
    }),
  };
}
