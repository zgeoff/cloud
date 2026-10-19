import { expect, test } from 'bun:test';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { buildNixieIngressChartArgs } from './build-nixie-ingress-chart-args.ts';
import { buildNixieIngressValues } from './build-nixie-ingress-values.ts';

test("it runs the controller in its own namespace and serves the Ingress objects of nixie's", () => {
  expect(
    buildNixieIngressChartArgs({
      controllerNamespace: 'nixie-ingress',
      routesNamespace: 'nixie',
      ingressClass: 'nixie',
    }),
  ).toStrictEqual({
    namespace: 'nixie-ingress',
    chart: 'traefik',
    version: '41.6.0',
    repositoryOpts: { repo: 'https://traefik.github.io/charts' },
    skipCrds: true,
    values: buildNixieIngressValues({
      httpsPort: geoffcloudNode.httpsPort,
      endpointIP: geoffcloudNode.ip,
      ingressClass: 'nixie',
      namespace: 'nixie',
    }),
  });
});
