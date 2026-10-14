// each test commits its own branch to a real origin, so its body is long
/* oxlint-disable max-statements */
import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readATCPinBranch } from './read-atc-pin-branch.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// a real origin and seed, and a runner that runs git for real without the user's config
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'read-atc-pin-branch-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = await createGitOrigin(dir);

  const stub = buildStubRunner(buildRealProgramHandler(['git'], repo.env));

  await mkdir(join(repo.seed, 'images/agent'), { recursive: true });

  return { repo, clone: join(dir, 'clone'), stub };
}

test('it reads the branch’s commit and the release its Dockerfile pins', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'ARG ATC_VERSION=3.10.2\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ubuntu:24.04\nARG ATC_VERSION=3.11.0\nARG ATC_SHA256=44\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'pin 3.11.0']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const head = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  const branch = await readATCPinBranch(
    { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
    ctx.clone,
    'atc-pin/agent-image',
  );

  expect(branch).toStrictEqual({ lease: head, version: '3.11.0' });
});

test('it reads a branch origin lacks as no lease and no release', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'ARG ATC_VERSION=3.10.2\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const branch = await readATCPinBranch(
    { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
    ctx.clone,
    'atc-pin/agent-image',
  );

  expect(branch).toStrictEqual({ lease: '', version: '' });
});

test('it stops with git’s exit code when origin cannot be reached', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'ARG ATC_VERSION=3.10.2\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);
  await ctx.repo.git(['-C', ctx.clone, 'remote', 'set-url', 'origin', join(ctx.clone, 'gone.git')]);

  expect(
    readATCPinBranch(
      { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
      ctx.clone,
      'atc-pin/agent-image',
    ),
  ).rejects.toMatchObject({ exitCode: 128 });
});
