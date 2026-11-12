import type { StackConfig } from '../inputs/types.ts';
import { buildMockATCGatewayConfig } from './build-mock-atc-gateway-config.ts';
import { buildStubConfig } from './build-stub-config.ts';

// a stack config that sets the gateway and its owner address, with one daemon
export function buildMockATCGatewayStackConfig(): StackConfig {
  return buildStubConfig({
    atcGateway: JSON.stringify(buildMockATCGatewayConfig()),
    atcGatewayOwnerEmail: 'owner@example.test',
  });
}
