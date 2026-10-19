// a pin callback reports success as undefined, as the branch builder's applyPins type says
/* oxlint-disable unicorn/no-useless-undefined */
import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createGitOrigin } from '../test-utils/create-git-origin.ts';
import { createBumpBranch } from './create-bump-branch.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'create-bump-branch-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const origin = await createGitOrigin(directory);

  const clone = join(directory, 'clone');
  const stub = buildStubRunner(buildRealProgramHandler(['git'], origin.env));

  return {
    origin,
    clone,
    context: { cwd: clone, env: origin.env, run: stub.run, printOut: () => {}, printErr: () => {} },
  };
}

test('it commits a new branch that origin lacks, with no lease', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const branch = await createBumpBranch(ctx.context, {
    dependency: 'nixie',
    version: '0.7.1',
    applyPins: async () => {
      await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.1\n');

      return undefined;
    },
  });

  const log = await ctx.origin.git(['-C', ctx.clone, 'log', '-1', '--format=%s']);

  expect(branch).toStrictEqual({
    name: 'release-check/nixie',
    title: 'chore(nixie): bump nixie to 0.7.1',
    lease: '',
    same: false,
    sameRelease: false,
  });

  expect(log).toBe('chore(nixie): bump nixie to 0.7.1');
});

test('it leases the branch on origin and finds the same change there', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const head = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  const branch = await createBumpBranch(ctx.context, {
    dependency: 'imp',
    version: '1.0.1',
    applyPins: async () => {
      await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

      return undefined;
    },
  });

  expect(branch).toStrictEqual({
    name: 'release-check/imp',
    title: 'chore(imp): bump imp to 1.0.1',
    lease: head,
    same: true,
    sameRelease: true,
  });
});

test('it gives the git error when origin is gone', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  await rm(ctx.origin.origin, { recursive: true });

  const branch = await createBumpBranch(ctx.context, {
    dependency: 'atc',
    version: '4.2.1',
    applyPins: () => Promise.resolve(new Error('the pin ran')),
  });

  expect(branch).toStrictEqual(
    new Error(
      `fatal: '${ctx.origin.origin}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.`,
    ),
  );
});
