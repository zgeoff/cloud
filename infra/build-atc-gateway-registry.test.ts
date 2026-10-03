import { describe, expect, test } from 'bun:test';
import { atcGatewayTokenVariable, buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';

describe('buildATCGatewayRegistry', () => {
  test("pins geoffcloud's daemon and makes it the default, in atc's format", () => {
    const registry = buildATCGatewayRegistry({
      address: '100.69.47.33:8415',
      daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
    });

    expect(registry).toEqual({
      daemons: {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
        },
      },
      defaultDaemon: 'geoffcloud',
    });
  });

  test("names the token variable atc derives from the daemon's name", () => {
    expect(atcGatewayTokenVariable).toBe('ATC_GATEWAY_TOKEN_GEOFFCLOUD');
  });
});
