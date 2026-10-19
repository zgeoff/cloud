import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveMainCommit } from './resolve-main-commit.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// a real origin and seed for each case to commit to
async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'resolve-main-commit-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const repo = await createGitOrigin(directory);

  const stub = buildStubRunner(buildRealProgramHandler(['git'], repo.env));

  return { directory, repo, clone: join(directory, 'clone'), stub };
}

test('it resolves a commit that reached main after the clone, through its fetch', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'README'), 'one\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'one']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(join(ctx.repo.seed, 'README'), 'two\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'two']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const commit = await resolveMainCommit(
    { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
    ctx.clone,
    'origin/main',
  );

  expect(commit).toStrictEqual({ sha, short });
});

test('it refuses a commit that main does not hold', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'README'), 'one\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'one']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'topic']);

  await writeFile(join(ctx.repo.seed, 'README'), 'two\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'two']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'topic']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  expect(
    resolveMainCommit(
      { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
      ctx.clone,
      'origin/topic',
    ),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: `${sha} is not on origin/main: build only a commit that main holds`,
  });
});

test('it stops with git’s exit code for a name that is no commit', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.repo.seed, 'README'), 'one\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'one']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  expect(
    resolveMainCommit(
      { run: ctx.stub.run, printOut: () => {}, printErr: () => {} },
      ctx.clone,
      'nowhere',
    ),
  ).rejects.toMatchObject({ exitCode: 128, message: '' });
});
