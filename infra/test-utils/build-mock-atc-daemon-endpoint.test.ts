import { expect, test } from 'bun:test';
import { buildMockATCDaemonEndpoint } from './build-mock-atc-daemon-endpoint.ts';

test('it builds a default atc daemon endpoint', () => {
  expect(buildMockATCDaemonEndpoint()).toStrictEqual({
    name: 'geoffcloud',
    address: '100.64.0.1:8415',
    alertSeverity: 'critical',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockATCDaemonEndpoint({ name: 'home-pc', alertSeverity: 'warning' })).toStrictEqual({
    name: 'home-pc',
    address: '100.64.0.1:8415',
    alertSeverity: 'warning',
  });
});
