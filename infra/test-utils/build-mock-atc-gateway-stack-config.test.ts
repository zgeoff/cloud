import { expect, test } from 'bun:test';
import { buildMockATCGatewayStackConfig } from './build-mock-atc-gateway-stack-config.ts';

test('it sets the gateway object with one daemon and the owner address', () => {
  const config = buildMockATCGatewayStackConfig();

  expect(config.getObject('atcGateway')).toMatchObject({ defaultDaemon: 'geoffcloud' });
  expect(config.get('atcGatewayOwnerEmail')).toBe('owner@example.test');
});

test('it sets a 7.14.0 gateway image unless a test names another', () => {
  expect(buildMockATCGatewayStackConfig().getObject('atcGateway')).toMatchObject({
    image: `ghcr.io/zgeoff/atc-gateway:7.14.0@sha256:${'a'.repeat(64)}`,
  });

  const older = `ghcr.io/zgeoff/atc-gateway:7.12.1@sha256:${'b'.repeat(64)}`;

  expect(buildMockATCGatewayStackConfig({ image: older }).getObject('atcGateway')).toMatchObject({
    image: older,
  });
});
