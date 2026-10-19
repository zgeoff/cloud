import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig, ATCGatewayDaemon } from '../inputs/types.ts';
import { buildMockATCGatewayDaemon } from './build-mock-atc-gateway-daemon.ts';

// stateDir's and trustForwardedFrom's absence is behaviour (the gateway takes $HOME's state dir,
// and trusts no proxy), so undefined leaves each out (exactOptionalPropertyTypes forbids plain
// overrides).
type ATCGatewayConfigOverrides = Partial<
  Omit<ATCGatewayConfig, 'daemons' | 'stateDir' | 'trustForwardedFrom'>
> & {
  readonly daemons?: Readonly<Record<string, Partial<ATCGatewayDaemon>>>;
  readonly stateDir?: string | undefined;
  readonly trustForwardedFrom?: string[] | undefined;
};

export function buildMockATCGatewayConfig(
  overrides: ATCGatewayConfigOverrides = {},
): ATCGatewayConfig {
  const { daemons, stateDir, trustForwardedFrom, ...fields } = {
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
    stateDir: faker.system.directoryPath(),
    trustForwardedFrom: [faker.internet.ipv4()],
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
    ...(trustForwardedFrom === undefined ? {} : { trustForwardedFrom }),
  };
}
