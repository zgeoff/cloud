import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createStubImpCLI } from './create-stub-imp-cli.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-stub-imp-cli-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it keeps the imps that one call creates for the next call, and logs each argv', async () => {
  const ctx = await setupTest();

  const imp = await createStubImpCLI(ctx.dir, {
    images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }],
  });

  await runProcess([
    join(imp.bin, 'impz'),
    'new',
    'agent-check-abc1234',
    '--image',
    'agent-abc1234',
  ]);

  const listed = await runProcess([join(imp.bin, 'impz'), 'ls', '--json']);

  expect(listed).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('[{"name":"agent-check-abc1234","image":"agent-abc1234"}]\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });

  const calls = await imp.readCalls();
  const state = await imp.readState();

  expect(calls).toStrictEqual([
    ['new', 'agent-check-abc1234', '--image', 'agent-abc1234'],
    ['ls', '--json'],
  ]);

  expect(state).toStrictEqual({
    images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-abc1234' }],
  });
});

test('it answers a failing call with buildStubImp’s exit code and stderr', async () => {
  const ctx = await setupTest();
  const imp = await createStubImpCLI(ctx.dir, { images: [] });
  const result = await runProcess([join(imp.bin, 'impz'), 'rm', 'agent-check-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from('impz: NOT_FOUND: imp agent-check-abc1234 not found\n'),
    timedOut: false,
  });
});

test('it fails a call it does not model with exit 97', async () => {
  const ctx = await setupTest();
  const imp = await createStubImpCLI(ctx.dir, { images: [] });
  const result = await runProcess([join(imp.bin, 'impz'), 'exec', 'agent-check-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 97,
    stdout: Buffer.from(''),
    stderr: Buffer.from('unexpected: ["impz","exec","agent-check-abc1234"]\n'),
    timedOut: false,
  });
});
