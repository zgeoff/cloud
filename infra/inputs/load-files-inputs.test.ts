import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { Output, isSecret, secret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../src/test-utils/build-stub-config.ts';
import { resolveOutput } from '../src/test-utils/resolve-output.ts';
import { loadFilesInputs } from './load-files-inputs.ts';

test('it returns nothing while the stack config leaves files out', () => {
  expect(
    loadFilesInputs(buildStubConfig({}), { FILES_OWNER_TOKEN: 'owner-token-for-tests' }, undefined),
  ).toStrictEqual({});
});

test('it returns the pinned image, the host name, the pull credential and the token hashes when files is set', () => {
  const stackConfig = buildStubConfig({
    files: JSON.stringify({
      image:
        'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
      hostname: 'files.geoff.cloud',
      agentTokenDigests: {
        nixie: '1111111111111111111111111111111111111111111111111111111111111111',
      },
    }),
  });

  expect(
    loadFilesInputs(
      stackConfig,
      {
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
  ['agent', 'the named digest', '1111111111111111111111111111111111111111111111111111111111111111'],
  [
    'owner',
    'the hex SHA-256 of the token',
    createHash('sha256').update('owner-token-for-tests').digest('hex'),
  ],
] as const)('it marks the %s token hash secret and carries %s', async (role, _label, expected) => {
  const inputs = loadFilesInputs(
    buildStubConfig({
      files: JSON.stringify({
        image:
          'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
        hostname: 'files.geoff.cloud',
        agentTokenDigests: {
          nixie: '1111111111111111111111111111111111111111111111111111111111111111',
        },
      }),
    }),
    {
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
  expect(value).toBe(expected);
});

test('it refuses a missing owner token', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
          agentTokenDigests: {
            nixie: '1111111111111111111111111111111111111111111111111111111111111111',
          },
        }),
      }),
      {
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
          agentTokenDigests: {
            nixie: '1111111111111111111111111111111111111111111111111111111111111111',
          },
        }),
      }),
      { FILES_OWNER_TOKEN: 'owner-token-for-tests' },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'stack config "files.image" must name an image by tag and digest');
});

test('it refuses an image that is not a string', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({ files: JSON.stringify({ image: 42, hostname: 'files.geoff.cloud' }) }),
      { FILES_OWNER_TOKEN: 'owner-token-for-tests' },
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
      { FILES_OWNER_TOKEN: 'owner-token-for-tests' },
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
        agentTokenDigests: {
          nixie: '1111111111111111111111111111111111111111111111111111111111111111',
        },
      }),
    }),
    {
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
          agentTokenDigests: {
            nixie: '1111111111111111111111111111111111111111111111111111111111111111',
          },
        }),
      }),
      {
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

test.each([
  ['each named digest', {}],
  [
    'only the named digests while FILES_AGENT_TOKEN is still set',
    { FILES_AGENT_TOKEN: 'agent-token-for-tests' },
  ],
])('it gives the service %s, split by commas', async (_label, agentEnv) => {
  const agentTokenDigests = { nixie: '1'.repeat(64), pepys: '2'.repeat(64) };

  const inputs = loadFilesInputs(
    buildStubConfig({
      files: JSON.stringify({
        image:
          'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
        hostname: 'files.geoff.cloud',
        agentTokenDigests,
      }),
    }),
    {
      ...agentEnv,
      FILES_OWNER_TOKEN: 'owner-token-for-tests',
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
    },
    undefined,
  );

  invariant(inputs.files);

  const value = await resolveOutput(inputs.files.tokenHashes.agent);

  expect(value).toBe(`${'1'.repeat(64)},${'2'.repeat(64)}`);
});

test('it refuses a files service with no agent token', () => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
          agentTokenDigests: {},
        }),
      }),
      {
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrowWithMessage(
    Error,
    'the files service needs an agent token: name its digest in stack config "files.agentTokenDigests"',
  );
});

test('it refuses one digest under two names', () => {
  const digest = '1'.repeat(64);

  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
          agentTokenDigests: { nixie: digest, pepys: digest },
        }),
      }),
      {
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'each agent token of the files service needs a digest of its own');
});

test('it refuses a named digest of the owner token', () => {
  const ownerDigest = createHash('sha256').update('owner-token-for-tests').digest('hex');

  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
          agentTokenDigests: { nixie: ownerDigest },
        }),
      }),
      {
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrowWithMessage(Error, 'FILES_OWNER_TOKEN must differ from every agent token');
});

test.each([
  ['a digest that is not hex', { nixie: 'z'.repeat(64) }],
  ['a name with capitals', { Nixie: 'a'.repeat(64) }],
])('it refuses %s', (_label, agentTokenDigests) => {
  expect(() =>
    loadFilesInputs(
      buildStubConfig({
        files: JSON.stringify({
          image:
            'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
          hostname: 'files.geoff.cloud',
          agentTokenDigests,
        }),
      }),
      {
        FILES_OWNER_TOKEN: 'owner-token-for-tests',
        GHCR_PULL_USERNAME: 'octo-puller',
        GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
      },
      undefined,
    ),
  ).toThrow(/stack config "files.agentTokenDigests/u);
});
