import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createGitOrigin } from '../test-utils/create-git-origin.ts';
import { runGitSteps } from './run-git-steps.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-git-steps-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const origin = await createGitOrigin(directory);

  const stub = buildStubRunner(buildRealProgramHandler(['git'], origin.env));

  return {
    origin,
    stub,
    context: {
      cwd: origin.seed,
      env: origin.env,
      run: stub.run,
      printOut: () => {},
      printErr: () => {},
    },
  };
}

test('it runs each step in the clone, in order', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  const result = await runGitSteps(ctx.context, [
    ['add', 'pins'],
    ['commit', '-qm', 'add the pins'],
  ]);

  const log = await ctx.origin.git(['-C', ctx.origin.seed, 'log', '--format=%s']);

  expect(result).toBeUndefined();
  expect(log).toBe('add the pins');
});

test('it stops at the first failed step and gives its error', async () => {
  const ctx = await setupTest();

  const result = await runGitSteps(ctx.context, [
    ['checkout', '-q', 'release-check/none'],
    ['commit', '-qm', 'never runs'],
  ]);

  expect(result).toStrictEqual(
    new Error("error: pathspec 'release-check/none' did not match any file(s) known to git"),
  );

  expect(ctx.stub.calls.map((call) => call.argv)).toStrictEqual([
    ['git', 'checkout', '-q', 'release-check/none'],
  ]);
});
