import { expect, test } from 'bun:test';
import { Output, output } from '@pulumi/pulumi';
import { buildMockTunnelRoute } from './build-mock-tunnel-route.ts';

test('it builds a default tunnel route', () => {
  expect(buildMockTunnelRoute()).toStrictEqual({
    hostname: expect.toSatisfy((hostname: string) => /^[\w-]+(?:\.[\w-]+)+$/u.test(hostname)),
    service: expect.toSatisfy((service: unknown) => Output.isInstance(service)),
  });
});

test('it applies overrides on top of the defaults', () => {
  const service = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(buildMockTunnelRoute({ service })).toStrictEqual({
    hostname: expect.toSatisfy((hostname: string) => /^[\w-]+(?:\.[\w-]+)+$/u.test(hostname)),
    service,
  });
});
