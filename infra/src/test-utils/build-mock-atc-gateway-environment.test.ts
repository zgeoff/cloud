import { expect, test } from 'bun:test';
import { buildMockATCGatewayEnvironment } from './build-mock-atc-gateway-environment.ts';

test('it builds the variables of one daemon and the pull credential', () => {
  expect(buildMockATCGatewayEnvironment()).toStrictEqual({
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: 'a-token' })).toMatchObject({
    BOXXY_ATC_TOKEN: 'a-token',
    GHCR_PULL_USERNAME: 'octo-puller',
  });
});
