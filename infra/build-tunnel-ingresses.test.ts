import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildTunnelIngresses } from './build-tunnel-ingresses.ts';

test("it sends the atc gateway's hostname to its service, with the 404 catch-all last", () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(buildTunnelIngresses({ hostname: 'atc.geoff.cloud', service })).toStrictEqual([
    { hostname: 'atc.geoff.cloud', service },
    { service: 'http_status:404' },
  ]);
});

test('it holds only the 404 catch-all without a route', () => {
  expect(buildTunnelIngresses(undefined)).toStrictEqual([{ service: 'http_status:404' }]);
});
