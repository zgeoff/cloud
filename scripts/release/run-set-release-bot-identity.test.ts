import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createGitOrigin } from '../test-utils/create-git-origin.ts';
import { runSetReleaseBotIdentity } from './run-set-release-bot-identity.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-set-release-bot-identity-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const origin = await createGitOrigin(directory);

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { origin, printOut, printErr };
}

test('it sets the bot user name and noreply address with its id', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubReleaseGH({ users: { 'cloud-release-check[bot]': 41_898_282 } }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await runSetReleaseBotIdentity(
    {
      cwd: ctx.origin.seed,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    ['cloud-release-check'],
  );

  const identity = await runProcess(
    ['git', '-C', ctx.origin.seed, 'config', '--local', '--get-regexp', String.raw`^user\.`],
    { env: ctx.origin.env },
  );

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);
  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(stub.calls[0]?.argv).toStrictEqual([
    'gh',
    'api',
    'users/cloud-release-check%5Bbot%5D',
    '--jq',
    '.id',
  ]);

  expect(identity.stdout.toString()).toBe(
    'user.name cloud-release-check[bot]\nuser.email 41898282+cloud-release-check[bot]@users.noreply.github.com\n',
  );
});

test('it fails with the gh error and sets nothing for a bot user github does not know', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubReleaseGH({ users: {} }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await runSetReleaseBotIdentity(
    {
      cwd: ctx.origin.seed,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    ['no-such-app'],
  );

  const identity = await runProcess(
    ['git', '-C', ctx.origin.seed, 'config', '--local', '--get-regexp', String.raw`^user\.`],
    { env: ctx.origin.env },
  );

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);
  expect(ctx.printErr.mock.calls).toStrictEqual([['gh: Not Found (HTTP 404)\n']]);

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['gh', 'api', 'users/no-such-app%5Bbot%5D', '--jq', '.id'],
  ]);

  expect(identity.stdout.toString()).toBe('');
});

test('it prints its usage without a slug', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runSetReleaseBotIdentity(
    {
      cwd: ctx.origin.seed,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    [],
  );

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: run-set-release-bot-identity.ts <app slug>\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});
