import { expect, test } from 'bun:test';
import { buildMockATCGatewayDaemonConfig } from './build-mock-atc-gateway-daemon-config.ts';

test('it builds a default atc gateway daemon config', () => {
  expect(buildMockATCGatewayDaemonConfig()).toStrictEqual({
    address: expect.toSatisfy((address: string) =>
      /^\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}$/u.test(address),
    ),
    daemonID: expect.toSatisfy((daemonID: string) =>
      /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
    ),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockATCGatewayDaemonConfig({ address: '100.67.122.120:8415', alertSeverity: 'warning' }),
  ).toStrictEqual({
    address: '100.67.122.120:8415',
    daemonID: expect.toSatisfy((daemonID: string) =>
      /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
    ),
    alertSeverity: 'warning',
  });
});
