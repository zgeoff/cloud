import { expect, test } from 'bun:test';
import { buildATCDaemonEndpoints } from './build-atc-daemon-endpoints.ts';
import { buildMockATCGatewayDaemon } from './test-utils/build-mock-atc-gateway-daemon.ts';

test("it gives each of the gateway's daemons, by name, with its address and alert severity", () => {
  const geoffcloud = buildMockATCGatewayDaemon({
    address: '100.69.47.33:8415',
    alertSeverity: 'critical',
  });

  const homePC = buildMockATCGatewayDaemon({
    address: '100.67.122.120:8415',
    alertSeverity: 'warning',
  });

  expect(buildATCDaemonEndpoints({ daemons: { geoffcloud, 'home-pc': homePC } })).toStrictEqual([
    { name: 'geoffcloud', address: '100.69.47.33:8415', alertSeverity: 'critical' },
    { name: 'home-pc', address: '100.67.122.120:8415', alertSeverity: 'warning' },
  ]);
});

test('it gives no daemons without the gateway', () => {
  expect(buildATCDaemonEndpoints(undefined)).toBeUndefined();
});
