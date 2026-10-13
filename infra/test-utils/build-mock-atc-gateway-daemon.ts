import { faker } from '@faker-js/faker';
import type { ATCGatewayDaemon } from '../inputs/types.ts';

// One daemon as the schema checks it: a host:port with a port of 1–65535, a lowercase UUID
// daemonID and a severity. A checked daemon is also a valid raw one, so the config and endpoint
// factories build their daemons from this one.
export function buildMockATCGatewayDaemon(
  overrides: Partial<ATCGatewayDaemon> = {},
): ATCGatewayDaemon {
  return {
    address: `${faker.internet.ipv4()}:${faker.number.int({ min: 1, max: 65_535 })}`,
    daemonID: faker.string.uuid(),
    alertSeverity: 'critical',
    ...overrides,
  };
}
