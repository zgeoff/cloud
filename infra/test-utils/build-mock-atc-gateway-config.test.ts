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
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockATCGatewayConfig({
      publicURL: 'https://atc.geoff.cloud',
      stateDir: '/var/lib/atc',
      defaultDaemon: 'geoffcloud',
    }),
  ).toStrictEqual({
    image: expect.toSatisfy((value: string) =>
      /^ghcr\.io\/zgeoff\/atc-gateway:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
    ),
    backupImage: expect.toSatisfy((value: string) =>
      /^ghcr\.io\/zgeoff\/atc-gateway-backup:\d+\.\d+\.\d+@sha256:[\da-f]{64}$/u.test(value),
    ),
    publicURL: 'https://atc.geoff.cloud',
    stateDir: '/var/lib/atc',
    defaultDaemon: 'geoffcloud',
  });
});
