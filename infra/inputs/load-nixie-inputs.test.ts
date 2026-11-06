import { expect, test } from 'bun:test';
import { Output, isSecret, secret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadNixieInputs } from './load-nixie-inputs.ts';

test('it returns nothing while the stack config leaves nixie out', () => {
  expect(
    loadNixieInputs(
      buildStubConfig({}),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toStrictEqual({});
});

test('it returns the pinned images, the host name and the 3 secrets when nixie is set', () => {
  const stackConfig = buildStubConfig({
    nixie: JSON.stringify({
      image:
        'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
      webImage:
        'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
      hostname: 'nixie.geoff.cloud',
    }),
  });

  expect(
    loadNixieInputs(
      stackConfig,
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toStrictEqual({
    nixie: {
      config: {
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        hostname: 'nixie.geoff.cloud',
      },
      secrets: {
        ageHostKey: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        definitionsDeployKey: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        dnsToken: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
    },
  });
});

test.each([
  ['ageHostKey', 'AGE-SECRET-KEY-1QQQ'],
  ['definitionsDeployKey', 'deploy-key'],
  ['dnsToken', 'cf-token'],
] as const)('it marks %s secret and carries its value as given', async (name, expected) => {
  const inputs = loadNixieInputs(
    buildStubConfig({
      nixie: JSON.stringify({
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        hostname: 'nixie.geoff.cloud',
      }),
    }),
    {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    },
    {
      username: 'octo-puller',
      token: secret('ghp_fake0token0for0tests0only0000000000'),
    },
  );

  invariant(inputs.nixie !== undefined, 'expected the nixie inputs');

  const isMarkedSecret = await isSecret(inputs.nixie.secrets[name]);
  const value = await resolveOutput(inputs.nixie.secrets[name]);

  expect(isMarkedSecret).toBeTrue();
  expect(value).toBe(expected);
});

test.each([
  ['NIXIE_AGE_HOST_KEY'],
  ['NIXIE_DEFINITIONS_DEPLOY_KEY'],
  ['CLOUDFLARE_API_TOKEN'],
] as const)('it throws when %s is unset while nixie is set', (name) => {
  const env: Record<string, string | undefined> = {
    NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
    NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
    CLOUDFLARE_API_TOKEN: 'cf-token',
    [name]: undefined,
  };

  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      env,
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(Error, `${name} is unset; nixie needs it while stack config "nixie" is set`);
});

test('it throws when a nixie secret holds only whitespace', () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: ' \n',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(
    Error,
    'NIXIE_AGE_HOST_KEY is blank; nixie needs it while stack config "nixie" is set',
  );
});

test.each([
  ['image', 'a tag alone', 'ghcr.io/zgeoff/nixie:0.1.0'],
  [
    'image',
    'a digest alone',
    'ghcr.io/zgeoff/nixie@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
  ],
  ['webImage', 'a tag alone', 'ghcr.io/zgeoff/nixie-web:0.1.0'],
] as const)('it throws when %s names %s', (key, _label, image) => {
  const config: Record<string, string> = {
    image:
      'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
    webImage:
      'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
    hostname: 'nixie.geoff.cloud',
    [key]: image,
  };

  expect(() =>
    loadNixieInputs(
      buildStubConfig({ nixie: JSON.stringify(config) }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(Error, `stack config "nixie.${key}" must name an image by tag and digest`);
});

test.each([
  ['no host name', undefined],
  ['a host outside geoff.cloud', 'nixie.example.com'],
  ['the zone apex', 'geoff.cloud'],
  ['a name with a space', 'nixie .geoff.cloud'],
] as const)('it throws when the hostname is %s', (_label, hostname) => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname,
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(Error, 'stack config "nixie.hostname" must name a host under geoff.cloud');
});

test('it throws when the hostname is not a string', () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: ['nixie.geoff.cloud'],
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
      },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "nixie.hostname" Invalid input: expected string, received array',
  );
});

test("it returns the backup with nixie's backup image, the gateway's pull credential and both repos' secrets when every NIXIE backup variable is set", () => {
  const pullCredential = {
    username: 'octo-puller',
    token: secret('ghp_fake0token0for0tests0only0000000000'),
  };

  const stackConfig = buildStubConfig({
    nixie: JSON.stringify({
      image:
        'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
      webImage:
        'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
      backupImage:
        'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
      hostname: 'nixie.geoff.cloud',
    }),
  });

  expect(
    loadNixieInputs(
      stackConfig,
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_KEY_RESTIC_PASSWORD: 'k'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      pullCredential,
    ).nixie?.backup,
  ).toStrictEqual({
    image:
      'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
    pullCredential,
    secrets: {
      dataRepository: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      dataPassword: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      keyRepository: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      keyPassword: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      accessKeyID: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      secretAccessKey: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
    },
  });
});

test.each([
  ['dataRepository', 's3:https://0123456789abcdef.r2.cloudflarestorage.com/nixie-backups/nixie'],
  ['dataPassword', 'p'.repeat(32)],
  [
    'keyRepository',
    's3:https://0123456789abcdef.r2.cloudflarestorage.com/nixie-backups/nixie-keys',
  ],
  ['keyPassword', 'k'.repeat(32)],
  ['accessKeyID', 'a'.repeat(32)],
  ['secretAccessKey', 's'.repeat(64)],
] as const)('it marks the backup %s secret and carries its value', async (name, expected) => {
  const inputs = loadNixieInputs(
    buildStubConfig({
      nixie: JSON.stringify({
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        backupImage:
          'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
        hostname: 'nixie.geoff.cloud',
      }),
    }),
    {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
      NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
      NIXIE_KEY_RESTIC_PASSWORD: 'k'.repeat(32),
      NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      NIXIE_R2_BUCKET: 'nixie-backups',
    },
    {
      username: 'octo-puller',
      token: secret('ghp_fake0token0for0tests0only0000000000'),
    },
  );

  invariant(inputs.nixie?.backup !== undefined, 'expected the nixie backup inputs');

  const isMarkedSecret = await isSecret(inputs.nixie.backup.secrets[name]);
  const value = await resolveOutput(inputs.nixie.backup.secrets[name]);

  expect(isMarkedSecret).toBeTrue();
  expect(value).toBe(expected);
});

test('it returns no backup when no NIXIE backup variable is set, even with a backup image', () => {
  const inputs = loadNixieInputs(
    buildStubConfig({
      nixie: JSON.stringify({
        image:
          'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
        webImage:
          'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
        backupImage:
          'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
        hostname: 'nixie.geoff.cloud',
      }),
    }),
    {
      NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
      NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
      CLOUDFLARE_API_TOKEN: 'cf-token',
    },
    {
      username: 'octo-puller',
      token: secret('ghp_fake0token0for0tests0only0000000000'),
    },
  );

  expect(inputs.nixie).not.toContainKey('backup');
});

test("it throws when the backup is set without the gateway's GHCR login", () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          backupImage:
            'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_KEY_RESTIC_PASSWORD: 'k'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'nixie\'s backup pulls its image with the GHCR login of stack config "atcGateway", which is unset: set atcGateway, or unset the NIXIE backup variables',
  );
});

test('it throws when the backup is set without nixie.backupImage', () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_KEY_RESTIC_PASSWORD: 'k'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "nixie.backupImage" must name an image by tag and digest',
  );
});

test.each([
  [
    "another release's nixie-backup",
    'ghcr.io/zgeoff/nixie-backup:0.2.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
  ],
  [
    'another backup image',
    'ghcr.io/zgeoff/atc-gateway-backup:0.1.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
  ],
] as const)('it throws when nixie.backupImage names %s', (_label, backupImage) => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          backupImage,
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_KEY_RESTIC_PASSWORD: 'k'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "nixie.backupImage" must name ghcr.io/zgeoff/nixie-backup:0.1.0, the release of nixie.image',
  );
});

test("it throws when the backup is set without the key repo's password", () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          backupImage:
            'ghcr.io/zgeoff/nixie-backup:0.1.0@sha256:5e0c1d5f3c7e2a9b8d4f6a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d1f3a5c7e9b',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(Error, "NIXIE_KEY_RESTIC_PASSWORD is unset; nixie's backup needs it");
});

test('it throws, naming the gap, when the nixie backup variables are partial', () => {
  expect(() =>
    loadNixieInputs(
      buildStubConfig({
        nixie: JSON.stringify({
          image:
            'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
          webImage:
            'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
          hostname: 'nixie.geoff.cloud',
        }),
      }),
      {
        NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1QQQ',
        NIXIE_DEFINITIONS_DEPLOY_KEY: 'deploy-key',
        CLOUDFLARE_API_TOKEN: 'cf-token',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
      },
      {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    ),
  ).toThrowWithMessage(
    Error,
    "nixie's backup needs every one of NIXIE_RESTIC_PASSWORD, NIXIE_R2_ACCESS_KEY_ID, NIXIE_R2_SECRET_ACCESS_KEY, NIXIE_R2_ENDPOINT, NIXIE_R2_BUCKET; unset: NIXIE_R2_ACCESS_KEY_ID, NIXIE_R2_SECRET_ACCESS_KEY, NIXIE_R2_ENDPOINT, NIXIE_R2_BUCKET",
  );
});
