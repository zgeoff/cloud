import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import { buildMockATCGatewayConfig } from '../test-utils/build-mock-atc-gateway-config.ts';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadATCGatewayInputs } from './load-atc-gateway-inputs.ts';

test('it returns no gateway while the stack config leaves atcGateway unset', () => {
  expect(
    loadATCGatewayInputs(buildStubConfig({}), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    }),
  ).toStrictEqual({});
});

test('it carries the checked config, the pull credential and a token per daemon, and leaves the backup out when its variables are unset', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {}, 'home-pc': { alertSeverity: 'warning' } },
    defaultDaemon: 'geoffcloud',
  });

  const stackConfig = buildStubConfig({ atcGateway: JSON.stringify(config) });

  expect(
    loadATCGatewayInputs(stackConfig, {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
    }),
  ).toStrictEqual({
    atcGateway: {
      config,
      secrets: {
        pullCredential: {
          username: 'octo-puller',
          token: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        },
        tokens: {
          geoffcloud: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
          'home-pc': expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        },
      },
    },
  });
});

test('it gives a daemon the stack config leaves without alertSeverity the severity critical', () => {
  const stackConfig = buildStubConfig({
    atcGateway: JSON.stringify({
      image: `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`,
      backupImage: `ghcr.io/zgeoff/atc-gateway-backup:3.0.0@sha256:${'1'.repeat(64)}`,
      publicURL: 'https://atc.geoff.cloud',
      daemons: {
        geoffcloud: {
          address: '100.69.47.33:8415',
          daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
        },
      },
      defaultDaemon: 'geoffcloud',
    }),
  });

  expect(
    loadATCGatewayInputs(stackConfig, {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    }).atcGateway?.config.daemons,
  ).toStrictEqual({
    geoffcloud: {
      address: '100.69.47.33:8415',
      daemonID: '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
      alertSeverity: 'critical',
    },
  });
});

test('it throws naming the field when the stack config fails the schema', () => {
  const stackConfig = buildStubConfig({
    atcGateway: JSON.stringify({
      ...buildMockATCGatewayConfig(),
      publicURL: 'atc.geoff.cloud',
    }),
  });

  expect(() =>
    loadATCGatewayInputs(stackConfig, {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    }),
  ).toThrowWithMessage(
    Error,
    'atcGateway.publicURL must be the https:// origin clients reach, such as https://atc.geoff.cloud',
  );
});

test('it marks every daemon token secret', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {}, 'home-pc': {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
  });

  if (result.atcGateway === undefined) {
    throw new Error('expected the gateway inputs');
  }

  expect(
    Promise.all(
      Object.entries(result.atcGateway.secrets.tokens).map(async ([name, token]) => [
        name,
        await isSecret(token),
      ]),
    ),
  ).resolves.toStrictEqual([
    ['geoffcloud', true],
    ['home-pc', true],
  ]);
});

test('it gives each daemon the token from its own ATC_GATEWAY_TOKEN_<NAME> variable', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {}, 'home-pc': {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
  });

  const tokens = result.atcGateway?.secrets.tokens;

  if (tokens === undefined) {
    throw new Error('expected the gateway inputs');
  }

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
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
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

  expect(isSecret(backup.repository)).resolves.toBeTrue();
  expect(isSecret(backup.password)).resolves.toBeTrue();
  expect(isSecret(backup.accessKeyID)).resolves.toBeTrue();
  expect(isSecret(backup.secretAccessKey)).resolves.toBeTrue();
});

test('it carries the backup values, with the restic repository built from the R2 endpoint and bucket', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
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

  expect(resolveOutput(backup.repository)).resolves.toBe(
    's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
  );

  expect(resolveOutput(backup.password)).resolves.toBe('p'.repeat(32));
  expect(resolveOutput(backup.accessKeyID)).resolves.toBe('a'.repeat(32));
  expect(resolveOutput(backup.secretAccessKey)).resolves.toBe('s'.repeat(64));
});

test("it throws when a daemon's token is missing from the environment it is given", () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {}),
  ).toThrowWithMessage(
    Error,
    "ATC_GATEWAY_TOKEN_GEOFFCLOUD is unset; .env must reference the daemon's token",
  );
});

test('it throws when only some backup variables are set in the environment it is given', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
    }),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET",
  );
});

test('it marks the pull token secret and carries it as given', async () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
  });

  const token = result.atcGateway?.secrets.pullCredential.token;

  if (token === undefined) {
    throw new Error('expected the pull credential');
  }

  const isMarkedSecret = await isSecret(token);
  const value = await resolveOutput(token);

  expect(isMarkedSecret).toBeTrue();
  expect(value).toBe('ghp_fake0token0for0tests0only0000000000');
});

test('it throws when the pull token is missing from the environment it is given', () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
    }),
  ).toThrowWithMessage(
    Error,
    "GHCR_PULL_TOKEN is unset; the atc gateway's images are private, so .env must reference op://cloud/ghcr-pull",
  );
});
