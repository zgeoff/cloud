import { expect, test } from 'bun:test';
import { Output, isSecret, secret } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { loadBoxxyInputs } from './load-boxxy-inputs.ts';

function setupTest() {
  const boxxy = {
    image:
      'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
    runner: 'runner-for-tests',
    atc: {
      trustedFolders: { 'target-for-tests': ['/workspace'] },
    },
    spawn: { target: 'target-for-tests' },
  };

  const repos = {
    'owner/repo': '/workspace/repo',
    'owner/other': { url: 'https://github.com/owner/other', ref: 'main' },
  };

  const tokens = {
    BOXXY_WORKER_TOKEN: 'worker-token-for-tests',
    BOXXY_ATC_TOKEN: 'atc-token-for-tests',
    GHCR_PULL_USERNAME: 'octo-puller',
    GHCR_PULL_TOKEN: 'ghp_fake0token0for0tests0only0000000000',
  };

  const backupVariables = {
    BOXXY_RESTIC_PASSWORD: 'p'.repeat(32),
    BOXXY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
    BOXXY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
    BOXXY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
    BOXXY_R2_BUCKET: 'backups',
  };

  const backupImage = {
    reference:
      'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:5555555555555555555555555555555555555555555555555555555555555555',
    pullCredential: {
      username: 'octo-puller',
      token: secret('ghp_fake0token0for0tests0only0000000000'),
    },
  };

  const stackValues = { boxxy: JSON.stringify(boxxy), boxxySpawnRepos: JSON.stringify(repos) };
  const stackConfig = buildStubConfig(stackValues);

  return { boxxy, repos, stackValues, stackConfig, tokens, backupVariables, backupImage };
}

test('it returns nothing while the stack config leaves boxxy out', () => {
  const fixture = setupTest();

  expect(loadBoxxyInputs(buildStubConfig({}), fixture.tokens, undefined)).toStrictEqual({});
});

test('it returns the config, the pull credential and both tokens when boxxy is set', () => {
  const fixture = setupTest();
  const inputs = loadBoxxyInputs(fixture.stackConfig, fixture.tokens, undefined);

  expect(inputs).toStrictEqual({
    boxxy: {
      config: fixture.boxxy,
      repos: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      pullCredential: {
        username: 'octo-puller',
        token: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
      secrets: {
        workerToken: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
        atcToken: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      },
    },
  });
});

test('it keeps the notice session when the stack config names one', () => {
  const fixture = setupTest();

  const withSession = {
    ...fixture.boxxy,
    atc: { ...fixture.boxxy.atc, noticeSession: 'owner-session' },
  };

  const stackConfig = buildStubConfig({
    ...fixture.stackValues,
    boxxy: JSON.stringify(withSession),
  });

  const inputs = loadBoxxyInputs(stackConfig, fixture.tokens, undefined);

  expect(inputs.boxxy?.config.atc.noticeSession).toBe('owner-session');
});

test('it marks the repos secret and carries them', async () => {
  const fixture = setupTest();
  const inputs = loadBoxxyInputs(fixture.stackConfig, fixture.tokens, undefined);

  invariant(inputs.boxxy);

  const secretRepos = await isSecret(inputs.boxxy.repos);
  const repos = await resolveOutput(inputs.boxxy.repos);

  expect(secretRepos).toBeTrue();
  expect(repos).toStrictEqual(fixture.repos);
});

test('it refuses boxxy without the repos key', () => {
  const fixture = setupTest();
  const stackConfig = buildStubConfig({ boxxy: fixture.stackValues.boxxy });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxySpawnRepos" is unset; the boxxy server spawns only in the repos it names: run `pulumi config set --secret boxxySpawnRepos < <file of JSON>` in infra/',
  );
});

test('it refuses repos in the boxxy block, where a private name would show', () => {
  const fixture = setupTest();
  const withRepos = { ...fixture.boxxy, spawn: { ...fixture.boxxy.spawn, repos: fixture.repos } };
  const stackConfig = buildStubConfig({ ...fixture.stackValues, boxxy: JSON.stringify(withRepos) });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.spawn" Unrecognized key: "repos"',
  );
});

test.each([
  ['workerToken', 'worker-token-for-tests'],
  ['atcToken', 'atc-token-for-tests'],
] as const)('it marks the %s secret and carries its value', async (key, value) => {
  const fixture = setupTest();
  const inputs = loadBoxxyInputs(fixture.stackConfig, fixture.tokens, undefined);

  invariant(inputs.boxxy);

  const token = inputs.boxxy.secrets[key];

  const secretToken = await isSecret(token);
  const resolved = await resolveOutput(token);

  expect(secretToken).toBeTrue();
  expect(resolved).toBe(value);
});

test('it refuses one token for both uses', () => {
  const fixture = setupTest();
  const tokens = { ...fixture.tokens, BOXXY_ATC_TOKEN: 'worker-token-for-tests' };

  expect(() => loadBoxxyInputs(fixture.stackConfig, tokens, undefined)).toThrowWithMessage(
    Error,
    'BOXXY_WORKER_TOKEN and BOXXY_ATC_TOKEN must differ',
  );
});

test('it refuses a missing atc token', () => {
  const fixture = setupTest();
  const { BOXXY_ATC_TOKEN: _, ...withoutATCToken } = fixture.tokens;

  expect(() => loadBoxxyInputs(fixture.stackConfig, withoutATCToken, undefined)).toThrowWithMessage(
    Error,
    'BOXXY_ATC_TOKEN is unset; the boxxy server needs it while stack config "boxxy" is set',
  );
});

test('it refuses an image without a digest', () => {
  const fixture = setupTest();
  const withTagOnly = { ...fixture.boxxy, image: 'ghcr.io/zgeoff/cloud-boxxy:0123456' };

  const stackConfig = buildStubConfig({
    ...fixture.stackValues,
    boxxy: JSON.stringify(withTagOnly),
  });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.image" must name an image by tag and digest',
  );
});

test('it refuses a config without a spawn target', () => {
  const fixture = setupTest();
  const withoutTarget = { ...fixture.boxxy, spawn: {} };

  const stackConfig = buildStubConfig({
    ...fixture.stackValues,
    boxxy: JSON.stringify(withoutTarget),
  });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.spawn.target" Invalid input: expected string, received undefined',
  );
});

test('it refuses a key the server configuration does not take', () => {
  const fixture = setupTest();
  const withStore = { ...fixture.boxxy, store: { file: '/tmp/boxxy-test/boxxy.db' } };
  const stackConfig = buildStubConfig({ ...fixture.stackValues, boxxy: JSON.stringify(withStore) });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy" Unrecognized key: "store"',
  );
});

test('it refuses an atc address, which the cluster sets from the gateway', () => {
  const fixture = setupTest();

  const withURL = {
    ...fixture.boxxy,
    atc: { ...fixture.boxxy.atc, url: 'http://atc.fixture.invalid:7777/rpc' },
  };

  const stackConfig = buildStubConfig({ ...fixture.stackValues, boxxy: JSON.stringify(withURL) });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.atc" Unrecognized key: "url"',
  );
});

test('it adds the backup in the backup image when every backup variable is set', async () => {
  const fixture = setupTest();
  const env = { ...fixture.tokens, ...fixture.backupVariables };
  const inputs = loadBoxxyInputs(fixture.stackConfig, env, fixture.backupImage);

  invariant(inputs.boxxy?.backup);

  const repository = await resolveOutput(inputs.boxxy.backup.secrets.repository);

  expect(inputs.boxxy.backup.image).toBe(fixture.backupImage.reference);
  expect(repository).toBe('s3:https://0123456789abcdef.r2.cloudflarestorage.com/backups/boxxy');
});

test('it refuses the backup variables without the backup image', () => {
  const fixture = setupTest();
  const env = { ...fixture.tokens, ...fixture.backupVariables };

  expect(() => loadBoxxyInputs(fixture.stackConfig, env, undefined)).toThrowWithMessage(
    Error,
    'the boxxy backup runs in stack config "atcGateway.backupImage", which is unset: set atcGateway, or unset the BOXXY backup variables',
  );
});
