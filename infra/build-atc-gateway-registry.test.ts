import { describe, expect, test } from 'bun:test';
import { buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';

const geoffcloud = {
  address: '100.69.47.33:8415',
  daemonID: '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b',
};

const homePC = { address: '100.67.122.120:8415', daemonID: '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d' };

describe('buildATCGatewayRegistry', () => {
  test("writes one daemon in atc's format, byte for byte as the single-daemon registry was", () => {
    const registry = buildATCGatewayRegistry({ geoffcloud }, 'geoffcloud');

    expect(JSON.stringify(registry)).toBe(
      '{"daemons":{"geoffcloud":{"address":"100.69.47.33:8415","daemonID":"0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b"}},"defaultDaemon":"geoffcloud"}',
    );
  });

  test('pins every daemon, keeps their order, and names the default', () => {
    expect(buildATCGatewayRegistry({ geoffcloud, 'home-pc': homePC }, 'home-pc')).toEqual({
      daemons: { geoffcloud, 'home-pc': homePC },
      defaultDaemon: 'home-pc',
    });
  });

  test('copies only address and daemonID', () => {
    const withExtra = { ...geoffcloud, token: 'never-in-the-registry' };

    expect(
      JSON.stringify(buildATCGatewayRegistry({ geoffcloud: withExtra }, 'geoffcloud')),
    ).not.toContain('never-in-the-registry');
  });
});
