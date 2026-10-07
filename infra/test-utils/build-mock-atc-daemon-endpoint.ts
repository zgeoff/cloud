import { faker } from '@faker-js/faker';
import type { ATCDaemonEndpoint } from '../build-alert-rules.ts';

export function buildMockATCDaemonEndpoint(
  overrides: Partial<ATCDaemonEndpoint> = {},
): ATCDaemonEndpoint {
  return {
    name: faker.internet.domainWord(),
    address: `${faker.internet.ipv4()}:${faker.internet.port()}`,
    alertSeverity: 'critical',
    ...overrides,
  };
}
