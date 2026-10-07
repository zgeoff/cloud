import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig } from '../atc-gateway.ts';
import { buildMockATCGatewayDaemonConfig } from './build-mock-atc-gateway-daemon-config.ts';
import type { ATCGatewayDaemonConfigOverrides } from './build-mock-atc-gateway-daemon-config.ts';

// An optional field's absence is behaviour (no daemons, no default daemon, the default
// state dir), so an override of undefined leaves it out: with exactOptionalPropertyTypes
// a plain override cannot. daemons is keyed by name, so its override names the daemons
// the config holds, and each daemon's override merges into fresh daemon defaults.
type ATCGatewayConfigOverrides = Partial<
  Omit<ATCGatewayConfig, 'daemons' | 'defaultDaemon' | 'stateDir'>
> & {
  readonly daemons?: Readonly<Record<string, ATCGatewayDaemonConfigOverrides>> | undefined;
  readonly defaultDaemon?: string | undefined;
  readonly stateDir?: string | undefined;
};

// A complete config, valid by requireATCGatewayInputs: one daemon under a name atc takes,
// and that daemon as the default
export function buildMockATCGatewayConfig(
  overrides: ATCGatewayConfigOverrides = {},
): ATCGatewayConfig {
  const { daemons, defaultDaemon, stateDir, ...fields } = {
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
    stateDir: faker.system.directoryPath(),
    ...overrides,
  };

  return {
    image: `ghcr.io/zgeoff/atc-gateway:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    publicURL: `https://${faker.internet.domainName()}`,
    ...fields,
    ...(daemons === undefined ? {} : { daemons: buildDaemons(daemons) }),
    ...(defaultDaemon === undefined ? {} : { defaultDaemon }),
    ...(stateDir === undefined ? {} : { stateDir }),
  };
}

function buildDaemons(
  overrides: Readonly<Record<string, ATCGatewayDaemonConfigOverrides>>,
): NonNullable<ATCGatewayConfig['daemons']> {
  return Object.fromEntries(
    Object.entries(overrides).map(([name, daemon]) => [
      name,
      buildMockATCGatewayDaemonConfig(daemon),
    ]),
  );
}
