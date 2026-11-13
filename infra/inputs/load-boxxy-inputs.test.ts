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

  // the review gate's part: review agents with the github section, and the noslop App's keys
  const review = {
    boxxy: {
      ...boxxy,
      spawn: { ...boxxy.spawn, reviewAgents: ['review-agent-for-tests'] },
      github: { baseUrl: 'https://api.github.com' },
    },
    env: {
      ...tokens,
      BOXXY_GITHUB_TOKEN: 'github-token-for-tests',
      NOSLOP_GITHUB_APP_ID: '123456',
      NOSLOP_GITHUB_APP_PRIVATE_KEY: 'private-key-for-tests',
      NOSLOP_GITHUB_APP_INSTALLATION_ID: '7890',
    },
  };

  return { boxxy, repos, stackValues, stackConfig, tokens, backupVariables, backupImage, review };
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

test('it refuses a notice session in the boxxy block, which the server reads from its environment', () => {
  const fixture = setupTest();

  const withSession = {
    ...fixture.boxxy,
    atc: { ...fixture.boxxy.atc, noticeSession: 'owner-session' },
  };

  const stackConfig = buildStubConfig({
    ...fixture.stackValues,
    boxxy: JSON.stringify(withSession),
  });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.atc" Unrecognized key: "noticeSession"',
  );
});

test('it keeps the public door when the stack config sets one', () => {
  const fixture = setupTest();

  const withDoor = {
    ...fixture.boxxy,
    publicDoor: { publicURL: 'https://boxxy.example.com', trustForwardedFrom: ['127.0.0.1'] },
  };

  const stackConfig = buildStubConfig({ ...fixture.stackValues, boxxy: JSON.stringify(withDoor) });
  const inputs = loadBoxxyInputs(stackConfig, fixture.tokens, undefined);

  expect(inputs.boxxy?.config.publicDoor).toStrictEqual({
    publicURL: 'https://boxxy.example.com',
    trustForwardedFrom: ['127.0.0.1'],
  });
});

test.each([
  ['plain http', 'http://boxxy.example.com'],
  ['a path', 'https://boxxy.example.com/mcp'],
  ['a trailing slash', 'https://boxxy.example.com/'],
])('it refuses a public door URL with %s', (_variant: string, publicURL: string) => {
  const fixture = setupTest();
  const withDoor = { ...fixture.boxxy, publicDoor: { publicURL, trustForwardedFrom: [] } };
  const stackConfig = buildStubConfig({ ...fixture.stackValues, boxxy: JSON.stringify(withDoor) });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.publicDoor.publicURL" must be the https:// origin clients reach, with no path, such as https://boxxy.example.com',
  );
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

test.each([
  ['pepys', { environment: 'production' }, 'BOXXY_PEPYS_SIGNING_SECRET', 'pepysSigningSecret'],
  ['github', { baseUrl: 'https://api.github.com' }, 'BOXXY_GITHUB_TOKEN', 'githubToken'],
] as const)(
  'it keeps the %s section and marks its token secret',
  async (section, value, variable, key) => {
    const fixture = setupTest();
    const withSection = { ...fixture.boxxy, [section]: value };

    const stackConfig = buildStubConfig({
      ...fixture.stackValues,
      boxxy: JSON.stringify(withSection),
    });

    const env = { ...fixture.tokens, [variable]: `${key}-for-tests` };
    const inputs = loadBoxxyInputs(stackConfig, env, undefined);

    invariant(inputs.boxxy);

    const token = inputs.boxxy.secrets[key];

    invariant(token);

    const secretToken = await isSecret(token);
    const resolved = await resolveOutput(token);

    expect(inputs.boxxy.config[section]).toStrictEqual(value);
    expect(secretToken).toBeTrue();
    expect(resolved).toBe(`${key}-for-tests`);
  },
);

test.each([
  [
    'pepys',
    { environment: 'production' },
    'BOXXY_PEPYS_SIGNING_SECRET is unset; the boxxy server signs its facts with it while stack config "boxxy.pepys" is set',
  ],
  [
    'github',
    { baseUrl: 'https://api.github.com' },
    'BOXXY_GITHUB_TOKEN is unset; the boxxy server reads pull requests with it while stack config "boxxy.github" is set',
  ],
] as const)('it refuses the %s section without its token', (section, value, message) => {
  const fixture = setupTest();
  const withSection = { ...fixture.boxxy, [section]: value };

  const stackConfig = buildStubConfig({
    ...fixture.stackValues,
    boxxy: JSON.stringify(withSection),
  });

  expect(() => loadBoxxyInputs(stackConfig, fixture.tokens, undefined)).toThrowWithMessage(
    Error,
    message,
  );
});

test('it adds no optional token while neither section is set', () => {
  const fixture = setupTest();

  const env = {
    ...fixture.tokens,
    BOXXY_PEPYS_SIGNING_SECRET: 'unused-secret',
    BOXXY_GITHUB_TOKEN: 'unused-token',
  };

  const inputs = loadBoxxyInputs(fixture.stackConfig, env, undefined);

  expect(Object.keys(inputs.boxxy?.secrets ?? {})).toStrictEqual(['workerToken', 'atcToken']);
});

test("it keeps the review agents and marks each of the noslop App's keys secret", async () => {
  const fixture = setupTest();
  const review = fixture.review;
  const stackValues = fixture.stackValues;

  const stackConfig = buildStubConfig({
    ...stackValues,
    boxxy: JSON.stringify(review.boxxy),
  });

  const inputs = loadBoxxyInputs(stackConfig, review.env, undefined);

  invariant(inputs.boxxy);

  const reviewApp = inputs.boxxy.secrets.reviewApp;

  invariant(reviewApp);

  const keys = [reviewApp.appID, reviewApp.privateKey, reviewApp.installationID];

  const secretKeys = await Promise.all(keys.map((key) => isSecret(key)));
  const resolved = await Promise.all(keys.map((key) => resolveOutput(key)));

  expect(inputs.boxxy.config.spawn).toStrictEqual({
    target: 'target-for-tests',
    reviewAgents: ['review-agent-for-tests'],
  });

  expect(secretKeys).toStrictEqual([true, true, true]);
  expect(resolved).toStrictEqual(['123456', 'private-key-for-tests', '7890']);
});

test.each([
  'NOSLOP_GITHUB_APP_ID',
  'NOSLOP_GITHUB_APP_PRIVATE_KEY',
  'NOSLOP_GITHUB_APP_INSTALLATION_ID',
] as const)('it refuses the review agents without %s', (variable) => {
  const fixture = setupTest();
  const review = fixture.review;
  const stackValues = fixture.stackValues;

  const stackConfig = buildStubConfig({
    ...stackValues,
    boxxy: JSON.stringify(review.boxxy),
  });

  const { [variable]: _left, ...env } = review.env;

  expect(() => loadBoxxyInputs(stackConfig, env, undefined)).toThrowWithMessage(
    Error,
    `${variable} is unset; the boxxy server posts each review as the noslop App with it while stack config "boxxy.spawn.reviewAgents" lists an agent`,
  );
});

test('it refuses the review agents without the github section', () => {
  const fixture = setupTest();
  const review = fixture.review;
  const stackValues = fixture.stackValues;
  const { github: _github, ...boxxy } = review.boxxy;
  const stackConfig = buildStubConfig({ ...stackValues, boxxy: JSON.stringify(boxxy) });

  expect(() => loadBoxxyInputs(stackConfig, review.env, undefined)).toThrowWithMessage(
    Error,
    'stack config "boxxy.spawn.reviewAgents" needs stack config "boxxy.github": the review gate reads the pull request\'s changes through it',
  );
});

test("it adds none of the noslop App's keys while no review agent is listed", () => {
  const fixture = setupTest();
  const review = fixture.review;
  const stackValues = fixture.stackValues;
  const boxxy = { ...review.boxxy, spawn: { ...review.boxxy.spawn, reviewAgents: [] } };
  const stackConfig = buildStubConfig({ ...stackValues, boxxy: JSON.stringify(boxxy) });
  const inputs = loadBoxxyInputs(stackConfig, review.env, undefined);

  expect(inputs.boxxy?.secrets.reviewApp).toBeUndefined();
});
