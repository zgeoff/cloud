import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig } from '../atc-gateway.ts';
import { buildMockATCGatewayDaemonConfig } from './build-mock-atc-gateway-daemon-config.ts';

// An optional field's absence is behaviour (no daemons, no default daemon, the default
// state dir), so an override of undefined leaves it out: with exactOptionalPropertyTypes
// a plain override cannot
type ATCGatewayConfigOverrides = Partial<
  Omit<ATCGatewayConfig, 'daemons' | 'defaultDaemon' | 'stateDir'>
> & {
  readonly daemons?: ATCGatewayConfig['daemons'] | undefined;
  readonly defaultDaemon?: string | undefined;
  readonly stateDir?: string | undefined;
};

// A complete config, valid by requireATCGatewayInputs: one daemon under a name atc takes,
// and that daemon as the default
export function buildMockATCGatewayConfig(
  overrides: ATCGatewayConfigOverrides = {},
): ATCGatewayConfig {
  const { daemons, defaultDaemon, stateDir, ...fields } = {
    daemons: { geoffcloud: buildMockATCGatewayDaemonConfig() },
    defaultDaemon: 'geoffcloud',
    stateDir: faker.system.directoryPath(),
    ...overrides,
  };

  return {
    image: `ghcr.io/zgeoff/atc-gateway:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    publicURL: `https://${faker.internet.domainName()}`,
    ...fields,
    ...(daemons === undefined ? {} : { daemons }),
    ...(defaultDaemon === undefined ? {} : { defaultDaemon }),
    ...(stateDir === undefined ? {} : { stateDir }),
  };
}
