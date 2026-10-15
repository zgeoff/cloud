import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMockTunnelRoute } from '../test-utils/build-mock-tunnel-route.ts';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

test("it sends the atc gateway's hostname to its service, with the 404 catch-all last", () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(
    buildTunnelIngresses([buildMockTunnelRoute({ hostname: 'atc.geoff.cloud', service })]),
  ).toStrictEqual([{ hostname: 'atc.geoff.cloud', service }, { service: 'http_status:404' }]);
});

test('it keeps each route in order and limits a route with a path to that path', () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(
    buildTunnelIngresses([
      buildMockTunnelRoute({ hostname: 'atc.geoff.cloud', service }),
      buildMockTunnelRoute({
        hostname: 'preview-webhook.geoff.cloud',
        service: 'http://100.69.47.33:8418',
        path: '^/webhook$',
      }),
    ]),
  ).toStrictEqual([
    { hostname: 'atc.geoff.cloud', service },
    {
      hostname: 'preview-webhook.geoff.cloud',
      path: '^/webhook$',
      service: 'http://100.69.47.33:8418',
    },
    { service: 'http_status:404' },
  ]);
});

test('it refuses a hostname that the exposure registry reserves', () => {
  expect(() =>
    buildTunnelIngresses([buildMockTunnelRoute({ hostname: 'imp.geoff.cloud' })]),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname imp.geoff.cloud is reserved in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it refuses a hostname that the exposure registry does not list', () => {
  expect(() =>
    buildTunnelIngresses([buildMockTunnelRoute({ hostname: 'grafana.geoff.cloud' })]),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname grafana.geoff.cloud is not in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test('it holds only the 404 catch-all without a route', () => {
  expect(buildTunnelIngresses([])).toStrictEqual([{ service: 'http_status:404' }]);
});
