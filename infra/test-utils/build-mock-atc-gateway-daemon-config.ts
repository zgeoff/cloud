import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig } from '../atc-gateway.ts';

type ATCGatewayDaemonConfig = NonNullable<ATCGatewayConfig['daemons']>[string];

// alertSeverity's absence is behaviour (the daemon takes critical), so an override of
// undefined leaves it out: with exactOptionalPropertyTypes a plain override cannot
interface ATCGatewayDaemonConfigOverrides {
  readonly address?: string;
  readonly daemonID?: string;
  readonly alertSeverity?: string | undefined;
}

// One daemon as the stack config gives it, valid by requireATCGatewayInputs: a host:port
// with a port of 1–65535, a lowercase UUID daemonID and a severity it takes
export function buildMockATCGatewayDaemonConfig(
  overrides: ATCGatewayDaemonConfigOverrides = {},
): ATCGatewayDaemonConfig & { readonly address: string; readonly daemonID: string } {
  const { alertSeverity, ...fields } = { alertSeverity: 'critical', ...overrides };

  return {
    address: `${faker.internet.ipv4()}:${faker.number.int({ min: 1, max: 65_535 })}`,
    daemonID: faker.string.uuid(),
    ...fields,
    ...(alertSeverity === undefined ? {} : { alertSeverity }),
  };
}
