import { expect, test } from 'bun:test';
import { buildMockATCGatewayStackConfig } from './build-mock-atc-gateway-stack-config.ts';

test('it sets the gateway object with one daemon and the owner address', () => {
  const config = buildMockATCGatewayStackConfig();

  expect(config.getObject('atcGateway')).toMatchObject({ defaultDaemon: 'geoffcloud' });
  expect(config.get('atcGatewayOwnerEmail')).toBe('owner@example.test');
});
