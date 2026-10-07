import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig } from '../atc-gateway.ts';

type ATCGatewayDaemonConfig = NonNullable<ATCGatewayConfig['daemons']>[string];

// One daemon as the stack config gives it, valid by requireATCGatewayInputs: a host:port
// with a port of 1–65535 and a lowercase UUID daemonID. alertSeverity stays absent, as
// in the stack config by default: with exactOptionalPropertyTypes an override cannot
// unset it.
export function buildMockATCGatewayDaemonConfig(
  overrides: Partial<ATCGatewayDaemonConfig> = {},
): ATCGatewayDaemonConfig & { readonly address: string; readonly daemonID: string } {
  return {
    address: `${faker.internet.ipv4()}:${faker.number.int({ min: 1, max: 65_535 })}`,
    daemonID: faker.string.uuid(),
    ...overrides,
  };
}
