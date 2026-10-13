import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig, ATCGatewayDaemon } from '../inputs/types.ts';
import { buildMockATCGatewayDaemon } from './build-mock-atc-gateway-daemon.ts';

// stateDir's absence is behaviour (the gateway takes $HOME's state dir), so undefined leaves it
// out (exactOptionalPropertyTypes forbids plain overrides). `daemons` names the daemons held;
// each merges into fresh defaults.
type ATCGatewayConfigOverrides = Partial<Omit<ATCGatewayConfig, 'daemons' | 'stateDir'>> & {
  readonly daemons?: Readonly<Record<string, Partial<ATCGatewayDaemon>>>;
  readonly stateDir?: string | undefined;
};

// A complete config as the schema checks it: one daemon under a name atc takes, and that daemon
// as the default. A checked config is also a valid raw one, so a test can write it as JSON.
export function buildMockATCGatewayConfig(
  overrides: ATCGatewayConfigOverrides = {},
): ATCGatewayConfig {
  const { daemons, stateDir, ...fields } = {
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
    daemons: Object.fromEntries(
      Object.entries(daemons).map(([name, daemon]) => [name, buildMockATCGatewayDaemon(daemon)]),
    ),
    ...(stateDir === undefined ? {} : { stateDir }),
  };
}
