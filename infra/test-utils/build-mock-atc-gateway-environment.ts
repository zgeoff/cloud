import type { Environment } from '../inputs/types.ts';

// the variables the gateway's inputs need: a daemon's token and the pull credential
export function buildMockATCGatewayEnvironment(overrides: Environment = {}): Environment {
  return {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    ...overrides,
  };
}
