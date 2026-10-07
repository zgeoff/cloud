import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import { loadATCGatewayInputs } from './load-atc-gateway-inputs.ts';
import { buildMockATCGatewayConfig } from './test-utils/build-mock-atc-gateway-config.ts';
import { buildMockATCGatewayDaemonConfig } from './test-utils/build-mock-atc-gateway-daemon-config.ts';
import { buildStubConfig } from './test-utils/build-stub-config.ts';
import { resolveOutput } from './test-utils/resolve-output.ts';

test('it returns no gateway while the stack config leaves atcGateway unset', () => {
  expect(
    loadATCGatewayInputs(buildStubConfig({}), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    }),
  ).toStrictEqual({});
});

test('it carries each daemon, the default daemon and a token per daemon, and leaves the backup out when its variables are unset', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: {
        address: '100.69.47.33:8415',
        daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
      },
      'home-pc': {
        address: '100.67.122.120:8415',
        daemonID: '5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b',
        alertSeverity: 'warning',
      },
    },
    defaultDaemon: 'geoffcloud',
  });

  const stackConfig = buildStubConfig({ atcGateway: JSON.stringify(config) });

  expect(
    loadATCGatewayInputs(stackConfig, {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
    }),
  ).toStrictEqual({
    atcGateway: {
      config,
      daemons: {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
          alertSeverity: 'critical',
        },
        'home-pc': {
          address: '100.67.122.120:8415',
          daemonID: '5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b',
          alertSeverity: 'warning',
        },
      },
      defaultDaemon: 'geoffcloud',
      secrets: {
        tokens: {
          geoffcloud: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
          'home-pc': expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        },
      },
    },
  });
});

test('it marks every daemon token secret', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
      'home-pc': buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
  });

  if (result.atcGateway === undefined) {
    throw new Error('expected the gateway inputs');
  }

  expect(
    Promise.all(Object.values(result.atcGateway.secrets.tokens).map((token) => isSecret(token))),
  ).resolves.toStrictEqual([true, true]);
});

test('it gives each daemon the token from its own ATC_GATEWAY_TOKEN_<NAME> variable', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
      'home-pc': buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
  });

  if (result.atcGateway === undefined) {
    throw new Error('expected the gateway inputs');
  }

  const tokens = result.atcGateway.secrets.tokens;

  expect(
    Promise.all(
      Object.entries(tokens).map(async ([name, token]) => [name, await resolveOutput(token)]),
    ),
  ).resolves.toStrictEqual([
    ['geoffcloud', 'g'.repeat(32)],
    ['home-pc', 'h'.repeat(32)],
  ]);
});

test('it marks every backup value secret when the backup variables are set', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
    ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
    ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
    ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
    ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
  });

  const backup = result.atcGateway?.secrets.backup;

  if (backup === undefined) {
    throw new Error('expected the backup secrets');
  }

  expect(
    Promise.all([
      isSecret(backup.repository),
      isSecret(backup.password),
      isSecret(backup.accessKeyID),
      isSecret(backup.secretAccessKey),
    ]),
  ).resolves.toStrictEqual([true, true, true, true]);
});

test('it carries the backup values, with the restic repository built from the R2 endpoint and bucket', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
    ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
    ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
    ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
    ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
  });

  const backup = result.atcGateway?.secrets.backup;

  if (backup === undefined) {
    throw new Error('expected the backup secrets');
  }

  expect(
    Promise.all([
      resolveOutput(backup.repository),
      resolveOutput(backup.password),
      resolveOutput(backup.accessKeyID),
      resolveOutput(backup.secretAccessKey),
    ]),
  ).resolves.toStrictEqual([
    's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
    'p'.repeat(32),
    'a'.repeat(32),
    's'.repeat(64),
  ]);
});

test("it throws when a daemon's token is missing from the environment it is given", () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {}),
  ).toThrowWithMessage(
    Error,
    "ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty: .env must reference the daemon's token",
  );
});

test('it throws when only some backup variables are set in the environment it is given', () => {
  const config = buildMockATCGatewayConfig({
    daemons: {
      geoffcloud: buildMockATCGatewayDaemonConfig(),
    },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
    }),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET",
  );
});
