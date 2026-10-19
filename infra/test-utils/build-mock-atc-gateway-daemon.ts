import { faker } from '@faker-js/faker';
import type { ATCGatewayDaemon } from '../inputs/types.ts';

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
