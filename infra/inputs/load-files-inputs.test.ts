import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { Output, isSecret, secret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadFilesInputs } from './load-files-inputs.ts';

test('it returns nothing while the stack config leaves files out', () => {
  expect(
    loadFilesInputs(
      buildStubConfig({}),
      { FILES_AGENT_TOKEN: 'agent-token-for-tests', FILES_OWNER_TOKEN: 'owner-token-for-tests' },
      undefined,
    ),
  ).toStrictEqual({});
});

test('it returns the pinned image, the host name, the pull credential and the token hashes when files is set', () => {
  const stackConfig = buildStubConfig({
    files: JSON.stringify({
      image:
        'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
      hostname: 'files.geoff.cloud',
    }),
  });

  expect(
    loadFilesInputs(
      stackConfig,
      {
        FILES_AGENT_TOKEN: 'agent-token-for-tests',
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toStrictEqual({
    files: {
      config: {
        image:
          'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
        hostname: 'files.geoff.cloud',
      },
      pullCredential: {
        username: 'octo-puller',
        token: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
      tokenHashes: {
        agent: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        owner: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
    },
  });
});

test.each([
  ['agent', 'agent-token-for-tests'],
  ['owner', 'owner-token-for-tests'],
] as const)(
  'it marks the %s token hash secret and carries the hex SHA-256 of the token',
  async (role, token) => {
    const inputs = loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
        }),
      }),
      {
        FILES_AGENT_TOKEN: 'agent-token-for-tests',
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    );

    invariant(inputs.files);

    const hash = inputs.files.tokenHashes[role];

    const secretHash = await isSecret(hash);
    const value = await resolveOutput(hash);

    expect(secretHash).toBeTrue();
    expect(value).toBe(createHash('sha256').update(token).digest('hex'));
  },
);

test('it refuses one token for both roles', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
        }),
      }),
      {
        FILES_AGENT_TOKEN: 'one-token-for-tests',
        FILES_OWNER_TOKEN: 'one-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'FILES_AGENT_TOKEN and FILES_OWNER_TOKEN must differ');
});

test('it refuses a missing owner token', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
        }),
      }),
      {
        FILES_AGENT_TOKEN: 'agent-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'FILES_OWNER_TOKEN is unset; the files service needs it while stack config "files" is set',
  );
});

test('it refuses an image without a digest', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image: 'ghcr.io/zgeoff/cloud-files:0123456',
          hostname: 'files.geoff.cloud',
        }),
      }),
      { FILES_AGENT_TOKEN: 'agent-token-for-tests', FILES_OWNER_TOKEN: 'owner-token-for-tests' },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'stack config "files.image" must name an image by tag and digest');
});

test('it refuses an image that is not a string', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({ files: JSON.stringify({ image: 42, hostname: 'files.geoff.cloud' }) }),
      { FILES_AGENT_TOKEN: 'agent-token-for-tests', FILES_OWNER_TOKEN: 'owner-token-for-tests' },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'stack config "files.image" Invalid input: expected string, received number',
  );
});

test('it refuses a host name outside geoff.cloud', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.example.com',
        }),
      }),
      { FILES_AGENT_TOKEN: 'agent-token-for-tests', FILES_OWNER_TOKEN: 'owner-token-for-tests' },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'stack config "files.hostname" must name a host under geoff.cloud');
});

test('it adds the backup in the backup image when every backup variable is set', async () => {
  const inputs = loadFilesInputs(
    buildStubConfig({
      files: JSON.stringify({
        image:
          'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
        hostname: 'files.geoff.cloud',
      }),
    }),
    {
      FILES_AGENT_TOKEN: 'agent-token-for-tests',
      FILES_OWNER_TOKEN: 'owner-token-for-tests',
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      FILES_RESTIC_PASSWORD: 'p'.repeat(32),
      FILES_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      FILES_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      FILES_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      FILES_R2_BUCKET: 'backups',
    },
    {
      reference:
        'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      pullCredential: {
        username: 'octo-puller',
        token: secret('ghp_fake0token0for0tests0only0000000000'),
      },
    },
  );

  invariant(inputs.files?.backup);

  expect(inputs.files.backup.image).toBe(
    'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
  );

  const repository = await resolveOutput(inputs.files.backup.secrets.repository);

  expect(repository).toBe('s3:https://0123456789abcdef.r2.cloudflarestorage.com/backups/files');
});

test('it refuses the backup variables without a backup image', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
        }),
      }),
      {
        FILES_AGENT_TOKEN: 'agent-token-for-tests',
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
        FILES_RESTIC_PASSWORD: 'p'.repeat(32),
        FILES_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        FILES_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        FILES_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        FILES_R2_BUCKET: 'backups',
      },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'the files backup runs in stack config "atcGateway.backupImage", which is unset: set atcGateway, or unset the FILES backup variables',
  );
});
