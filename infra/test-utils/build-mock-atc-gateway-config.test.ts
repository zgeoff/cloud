import { expect, test } from 'bun:test';
import { buildMockATCGatewayConfig } from './build-mock-atc-gateway-config.ts';

test('it builds a default atc gateway config', () => {
  expect(buildMockATCGatewayConfig()).toStrictEqual({
    image: expect.toSatisfy((value: string) =>
      /^ghcr\.io\/zgeoff\/atc-gateway:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
    ),
    backupImage: expect.toSatisfy((value: string) =>
      /^ghcr\.io\/zgeoff\/atc-gateway-backup:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
    ),
    publicURL: expect.toSatisfy((value: string) => /^https:\/\/[\w.-]+$/u.test(value)),
    daemons: {
      geoffcloud: {
        address: expect.toSatisfy((address: string) =>
          /^\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}$/u.test(address),
        ),
        daemonID: expect.toSatisfy((daemonID: string) =>
          /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
        ),
        alertSeverity: 'critical',
      },
    },
    defaultDaemon: 'geoffcloud',
    stateDir: expect.toStartWith('/'),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect([
    buildMockATCGatewayConfig({
      publicURL: 'https://atc.geoff.cloud',
      daemons: { 'home-pc': { address: '100.67.122.120:8415' } },
      defaultDaemon: 'home-pc',
      stateDir: '/var/lib/atc',
    }),
    buildMockATCGatewayConfig({
      daemons: undefined,
      defaultDaemon: undefined,
      stateDir: undefined,
    }),
  ]).toStrictEqual([
    {
      image: expect.toSatisfy((value: string) =>
        /^ghcr\.io\/zgeoff\/atc-gateway:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
      ),
      backupImage: expect.toSatisfy((value: string) =>
        /^ghcr\.io\/zgeoff\/atc-gateway-backup:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
      ),
      publicURL: 'https://atc.geoff.cloud',
      daemons: {
        'home-pc': {
          address: '100.67.122.120:8415',
          daemonID: expect.toSatisfy((daemonID: string) =>
            /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u.test(daemonID),
          ),
          alertSeverity: 'critical',
        },
      },
      defaultDaemon: 'home-pc',
      stateDir: '/var/lib/atc',
    },
    {
      image: expect.toSatisfy((value: string) =>
        /^ghcr\.io\/zgeoff\/atc-gateway:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
      ),
      backupImage: expect.toSatisfy((value: string) =>
        /^ghcr\.io\/zgeoff\/atc-gateway-backup:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
      ),
      publicURL: expect.toSatisfy((value: string) => /^https:\/\/[\w.-]+$/u.test(value)),
    },
  ]);
});
