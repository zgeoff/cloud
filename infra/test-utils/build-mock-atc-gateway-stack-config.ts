import type { ATCGatewayConfig, StackConfig } from '../inputs/types.ts';
import { buildMockATCGatewayConfig } from './build-mock-atc-gateway-config.ts';
import { buildStubConfig } from './build-stub-config.ts';

const digest = 'a'.repeat(64);

// a stack config that sets the gateway and its owner address, with one daemon. The image defaults
// to a 7.14.0 one, so a test of the service token does not hang on a random release.
export function buildMockATCGatewayStackConfig(
  overrides: Partial<Pick<ATCGatewayConfig, 'image'>> = {},
): StackConfig {
  return buildStubConfig({
    atcGateway: JSON.stringify(
      buildMockATCGatewayConfig({
        image: `ghcr.io/zgeoff/atc-gateway:7.14.0@sha256:${digest}`,
        ...overrides,
      }),
    ),
    atcGatewayOwnerEmail: 'owner@example.test',
  });
}
