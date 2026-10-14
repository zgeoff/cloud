import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';
import { buildMockTunnelRoute } from './test-utils/build-mock-tunnel-route.ts';

test("it sends the atc gateway's hostname to its service, with the 404 catch-all last", () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(
    buildTunnelIngresses(buildMockTunnelRoute({ hostname: 'atc.geoff.cloud', service })),
  ).toStrictEqual([{ hostname: 'atc.geoff.cloud', service }, { service: 'http_status:404' }]);
});

test('it refuses a hostname that the exposure registry reserves', () => {
  expect(() =>
    buildTunnelIngresses(buildMockTunnelRoute({ hostname: 'imp.geoff.cloud' })),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname imp.geoff.cloud is reserved in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it refuses a hostname that the exposure registry does not list', () => {
  expect(() =>
    buildTunnelIngresses(buildMockTunnelRoute({ hostname: 'grafana.geoff.cloud' })),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname grafana.geoff.cloud is not in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it holds only the 404 catch-all without a route', () => {
  expect(buildTunnelIngresses(undefined)).toStrictEqual([{ service: 'http_status:404' }]);
});
