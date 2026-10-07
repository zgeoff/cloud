import { faker } from '@faker-js/faker';
import { output } from '@pulumi/pulumi';
import type { TunnelRoute } from '../build-tunnel-ingresses.ts';

export function buildMockTunnelRoute(overrides: Partial<TunnelRoute> = {}): TunnelRoute {
  return {
    hostname: faker.internet.domainName(),
    service: output(
      `http://${faker.internet.domainWord()}.svc.cluster.local:${faker.internet.port()}`,
    ),
    ...overrides,
  };
}
