import { expect, test } from 'bun:test';
import { buildMockATCGatewayDaemon } from './build-mock-atc-gateway-daemon.ts';

test('it builds a default atc gateway daemon', () => {
  expect(buildMockATCGatewayDaemon()).toStrictEqual({
    address: expect.toSatisfy((address: string) =>
      /^\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}$/u.test(address),
    ),
    daemonID: expect.toSatisfy((daemonID: string) =>
      /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
    ),
    alertSeverity: 'critical',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockATCGatewayDaemon({ address: '100.67.122.120:8415', alertSeverity: 'warning' }),
  ).toStrictEqual({
    address: '100.67.122.120:8415',
    daemonID: expect.toSatisfy((daemonID: string) =>
      /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
    ),
    alertSeverity: 'warning',
  });
});
