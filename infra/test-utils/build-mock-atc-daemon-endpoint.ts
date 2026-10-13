import { faker } from '@faker-js/faker';
import type { ATCDaemonEndpoint } from '../inputs/types.ts';
import { buildMockATCGatewayDaemon } from './build-mock-atc-gateway-daemon.ts';

// a daemon's endpoint: a name, and the address and severity of buildMockATCGatewayDaemon's daemon
export function buildMockATCDaemonEndpoint(
  overrides: Partial<ATCDaemonEndpoint> = {},
): ATCDaemonEndpoint {
  const { name = faker.internet.domainWord(), ...daemonOverrides } = overrides;
  const daemon = buildMockATCGatewayDaemon(daemonOverrides);

  return { name, address: daemon.address, alertSeverity: daemon.alertSeverity };
}
