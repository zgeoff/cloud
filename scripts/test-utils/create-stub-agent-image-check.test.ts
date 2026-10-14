import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { createStubAgentImageCheck } from './create-stub-agent-image-check.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-stub-agent-image-check-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  // a failed mkfifo leaves no fifo, so the read of it fails the test
  const fifo = join(dir, 'check-started');

  await runProcess(['mkfifo', fifo]);

  return { dir, fifo };
}

test('it writes a check that passes at once without CHECK_STARTED', async () => {
  const ctx = await setupTest();
  const path = await createStubAgentImageCheck(ctx.dir);

  const result = await runProcess(['bun', path, '--imp', 'agent-check-abc1234'], {
    env: { PATH: process.env['PATH'] },
  });

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('== 0 failed\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it writes a check that signals the fifo and then runs until it is stopped', async () => {
  const ctx = await setupTest();
  const path = await createStubAgentImageCheck(ctx.dir);

  const controller = new AbortController();

  const running = runProcess(['bun', path, '--imp', 'agent-check-abc1234'], {
    env: { PATH: process.env['PATH'], CHECK_STARTED: ctx.fifo },
    signal: controller.signal,
  });

  const started = await readFile(ctx.fifo, 'utf8');

  controller.abort();

  const result = await running;

  expect(started).toBe('started\n');
  expect(result.exitCode).toBe(143);
});
