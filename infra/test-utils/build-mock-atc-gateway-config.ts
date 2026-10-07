import { faker } from '@faker-js/faker';
import type { ATCGatewayConfig } from '../atc-gateway.ts';

// The optional fields stay absent: with exactOptionalPropertyTypes an override cannot
// unset a field, so a default here would make the unset case unreachable.
export function buildMockATCGatewayConfig(
  overrides: Partial<ATCGatewayConfig> = {},
): ATCGatewayConfig {
  return {
    image: `ghcr.io/zgeoff/atc-gateway:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    backupImage: `ghcr.io/zgeoff/atc-gateway-backup:${faker.system.semver()}@sha256:${faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' })}`,
    publicURL: `https://${faker.internet.domainName()}`,
    ...overrides,
  };
}
