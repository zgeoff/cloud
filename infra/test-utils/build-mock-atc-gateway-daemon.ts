import { faker } from '@faker-js/faker';
import type { ATCGatewayInputs } from '../atc-gateway.ts';

type ATCGatewayDaemon = ATCGatewayInputs['daemons'][string];

export function buildMockATCGatewayDaemon(
  overrides: Partial<ATCGatewayDaemon> = {},
): ATCGatewayDaemon {
  return {
    address: `${faker.internet.ipv4()}:${faker.internet.port()}`,
    daemonID: faker.string.uuid(),
    alertSeverity: 'critical',
    ...overrides,
  };
}
