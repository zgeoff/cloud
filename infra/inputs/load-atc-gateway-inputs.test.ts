import { expect, test } from 'bun:test';
import { Output, isSecret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildMockATCGatewayConfig } from '../test-utils/build-mock-atc-gateway-config.ts';
import { buildMockATCGatewayEnvironment } from '../test-utils/build-mock-atc-gateway-environment.ts';
import { buildMockATCGatewayStackConfig } from '../test-utils/build-mock-atc-gateway-stack-config.ts';
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

  const stackConfig = buildStubConfig({
    atcGateway: JSON.stringify(config),
    atcGatewayOwnerEmail: 'owner@example.test',
  });

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
        ownerEmail: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
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
    atcGatewayOwnerEmail: 'owner@example.test',
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

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
    },
  );

  invariant(result.atcGateway !== undefined, 'expected the gateway inputs');

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

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_TOKEN_HOME_PC: 'h'.repeat(32),
    },
  );

  const tokens = result.atcGateway?.secrets.tokens;

  invariant(tokens !== undefined, 'expected the gateway inputs');

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

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
    },
  );

  const backup = result.atcGateway?.secrets.backup;

  invariant(backup !== undefined, 'expected the backup secrets');

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

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
    },
  );

  const backup = result.atcGateway?.secrets.backup;

  invariant(backup !== undefined, 'expected the backup secrets');

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
    loadATCGatewayInputs(
      buildStubConfig({
        atcGateway: JSON.stringify(config),
        atcGatewayOwnerEmail: 'owner@example.test',
      }),
      {},
    ),
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
    loadATCGatewayInputs(
      buildStubConfig({
        atcGateway: JSON.stringify(config),
        atcGatewayOwnerEmail: 'owner@example.test',
      }),
      {
        ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      },
    ),
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

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    },
  );

  const token = result.atcGateway?.secrets.pullCredential.token;

  invariant(token !== undefined, 'expected the pull credential');

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
    loadATCGatewayInputs(
      buildStubConfig({
        atcGateway: JSON.stringify(config),
        atcGatewayOwnerEmail: 'owner@example.test',
      }),
      {
        ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
        GHCR_PULL_USERNAME: 'octo-puller',
      },
    ),
  ).toThrowWithMessage(
    Error,
    "GHCR_PULL_TOKEN is unset; the atc gateway's images are private, so .env must reference op://cloud/ghcr-pull",
  );
});

test("it carries the owner's address from the secret stack config, still marked secret", async () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  const result = loadATCGatewayInputs(
    buildStubConfig({
      atcGateway: JSON.stringify(config),
      atcGatewayOwnerEmail: 'owner@example.test',
    }),
    {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    },
  );

  const ownerEmail = result.atcGateway?.secrets.ownerEmail;

  invariant(ownerEmail !== undefined, "expected the owner's address");

  const isMarkedSecret = await isSecret(ownerEmail);
  const value = await resolveOutput(ownerEmail);

  expect(isMarkedSecret).toBeTrue();
  expect(value).toBe('owner@example.test');
});

test("it throws naming the config command when the owner's address is unset", () => {
  const config = buildMockATCGatewayConfig({
    daemons: { geoffcloud: {} },
    defaultDaemon: 'geoffcloud',
  });

  expect(() =>
    loadATCGatewayInputs(buildStubConfig({ atcGateway: JSON.stringify(config) }), {
      ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'g'.repeat(32),
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    }),
  ).toThrowWithMessage(
    Error,
    "atcGatewayOwnerEmail is unset; the Access policy in front of the gateway's sign-in pages needs it: run `pulumi config set --secret atcGatewayOwnerEmail <owner address>` in infra/",
  );
});

test('it carries the boxxy service token, as a secret, while BOXXY_ATC_TOKEN is set and the pinned release knows the flag', async () => {
  const token = `atcs_${'b'.repeat(40)}`;

  const serviceTokens = loadATCGatewayInputs(
    buildMockATCGatewayStackConfig(),
    buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: token }),
    { readRelease: () => '7.14.0', warn: () => {} },
  ).atcGateway?.secrets.serviceTokens;

  invariant(serviceTokens?.['boxxy'] !== undefined, 'expected the boxxy service token');

  const marked = await isSecret(serviceTokens['boxxy']);
  const value = await resolveOutput(serviceTokens['boxxy']);

  expect(Object.keys(serviceTokens)).toStrictEqual(['boxxy']);
  expect(marked).toBe(true);
  expect(value).toBe(token);
});

test.each(['7.14.0', '7.14.1', '7.15.0', '8.0.0', '10.0.0'])(
  'it carries the service token, with no warning, for the pinned release %s',
  (release) => {
    const warnings: string[] = [];

    const result = loadATCGatewayInputs(
      buildMockATCGatewayStackConfig(),
      buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: `atcs_${'b'.repeat(40)}` }),
      {
        readRelease: () => release,
        warn: (line) => {
          warnings.push(line);
        },
      },
    );

    expect(result.atcGateway?.secrets).toHaveProperty('serviceTokens');
    expect(warnings).toStrictEqual([]);
  },
);

test.each(['7.12.1', '7.13.9', '6.99.99', '2.24.0'])(
  'it leaves the service token out, with one warning that never holds the token, for the pinned release %s',
  (release) => {
    const token = `atcs_${'b'.repeat(40)}`;
    const warnings: string[] = [];

    const result = loadATCGatewayInputs(
      buildMockATCGatewayStackConfig(),
      buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: token }),
      {
        readRelease: () => release,
        warn: (line) => {
          warnings.push(line);
        },
      },
    );

    expect(result.atcGateway?.secrets).not.toHaveProperty('serviceTokens');

    expect(warnings).toStrictEqual([
      `BOXXY_ATC_TOKEN is set, but images/atc-gateway/versions.env pins atc ${release}, and --service-token-file needs 7.14.0: the gateway deploys without the boxxy service token`,
    ]);
  },
);

test.each(['7.12.1', '7.13.9'])(
  'it leaves the service token out, with one warning, while the pin is 7.14.0 and the configured image is release %s',
  (imageRelease) => {
    const token = `atcs_${'b'.repeat(40)}`;
    const warnings: string[] = [];

    const result = loadATCGatewayInputs(
      buildMockATCGatewayStackConfig({
        image: `ghcr.io/zgeoff/atc-gateway:${imageRelease}@sha256:${'c'.repeat(64)}`,
      }),
      buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: token }),
      {
        readRelease: () => '7.14.0',
        warn: (line) => {
          warnings.push(line);
        },
      },
    );

    expect(result.atcGateway?.secrets).not.toHaveProperty('serviceTokens');

    expect(warnings).toStrictEqual([
      `BOXXY_ATC_TOKEN is set, but the stack's atcGateway.image is release ${imageRelease}, and --service-token-file needs 7.14.0: the gateway deploys without the boxxy service token`,
    ]);
  },
);

test('it leaves the service token out, with one warning, while the configured image tag is not a release', () => {
  const warnings: string[] = [];

  const result = loadATCGatewayInputs(
    buildMockATCGatewayStackConfig({
      image: `ghcr.io/zgeoff/atc-gateway:latest-build@sha256:${'c'.repeat(64)}`,
    }),
    buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: `atcs_${'b'.repeat(40)}` }),
    {
      readRelease: () => '7.14.0',
      warn: (line) => {
        warnings.push(line);
      },
    },
  );

  expect(result.atcGateway?.secrets).not.toHaveProperty('serviceTokens');
  expect(warnings).toHaveLength(1);
  expect(warnings[0]).toContain('is not a release tag');
});

test('it loads, with the warning, a BOXXY_ATC_TOKEN of the older shape while the pinned release lacks the flag', () => {
  const warnings: string[] = [];

  const result = loadATCGatewayInputs(
    buildMockATCGatewayStackConfig(),
    buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: 'f'.repeat(64) }),
    {
      readRelease: () => '7.12.1',
      warn: (line) => {
        warnings.push(line);
      },
    },
  );

  expect(result.atcGateway?.secrets).not.toHaveProperty('serviceTokens');
  expect(warnings).toHaveLength(1);
});

test.each([
  ['unset', undefined],
  ['blank', '  '],
])(
  'it carries no service token and prints no warning while BOXXY_ATC_TOKEN is %s',
  (_name, value) => {
    const warnings: string[] = [];

    const result = loadATCGatewayInputs(
      buildMockATCGatewayStackConfig(),
      buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: value }),
      {
        readRelease: () => '7.14.0',
        warn: (line) => {
          warnings.push(line);
        },
      },
    );

    expect(result.atcGateway?.secrets).not.toHaveProperty('serviceTokens');
    expect(warnings).toStrictEqual([]);
  },
);

test.each([
  ['lacks the atcs_ prefix', 'f'.repeat(64)],
  ['is shorter than 32 characters after the prefix', `atcs_${'b'.repeat(31)}`],
  ['holds a character outside A-Z, a-z, 0-9, _ and -', `atcs_${'b'.repeat(40)}!`],
  ['holds whitespace', `atcs_${'b'.repeat(20)} ${'b'.repeat(20)}`],
])('it refuses a BOXXY_ATC_TOKEN that %s, without printing it', (_name, token) => {
  const load = () =>
    loadATCGatewayInputs(
      buildMockATCGatewayStackConfig(),
      buildMockATCGatewayEnvironment({ BOXXY_ATC_TOKEN: token }),
      { readRelease: () => '7.14.0', warn: () => {} },
    );

  expect(load).toThrowWithMessage(
    Error,
    'BOXXY_ATC_TOKEN must be atcs_ followed by 32 or more of A-Z, a-z, 0-9, _ and -, the shape of an atc service token',
  );
});
