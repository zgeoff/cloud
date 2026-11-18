import { expect, test } from 'bun:test';
import { buildMockATCDaemonEndpoint } from './build-mock-atc-daemon-endpoint.ts';

test('it builds a default atc daemon endpoint', () => {
  expect(buildMockATCDaemonEndpoint()).toStrictEqual({
    name: expect.toSatisfy((name: string) => /^[a-z0-9-]+$/u.test(name)),
    address: expect.toSatisfy((address: string) =>
      /^\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}$/u.test(address),
    ),
    alertSeverity: 'critical',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockATCDaemonEndpoint({ name: 'home-pc', alertSeverity: 'warning' })).toStrictEqual({
    name: 'home-pc',
    address: expect.toSatisfy((address: string) =>
      /^\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}$/u.test(address),
    ),
    alertSeverity: 'warning',
  });
});
