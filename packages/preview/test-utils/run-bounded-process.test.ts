import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { processDeps } from './process-deps.ts';
import { runBoundedProcess } from './run-bounded-process.ts';
import type { BoundedProcessDeps } from './run-bounded-process.ts';
import { waitForCondition } from './wait-for-condition.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'bounded-process-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const clock = { now: 1000 };
  const deadline = Promise.withResolvers<void>();

  const deps: BoundedProcessDeps = {
    ...processDeps,
    sleep: () => deadline.promise,
    now: () => clock.now,
  };

  return { directory, clock, deadline, deps };
}

test('it returns the exit code, stdout and stderr of a process that ends within its bound', async () => {
  const ctx = await setupTest();

  const result = await runBoundedProcess(ctx.deps, {
    name: 'the greeting',
    argv: ['sh', '-c', 'echo hello; echo warning >&2; exit 3'],
    timeoutMs: 2000,
  });

  expect(result).toStrictEqual({ exitCode: 3, stdout: 'hello\n', stderr: 'warning\n' });
});

test('it runs the process in the given directory with the given environment', async () => {
  const ctx = await setupTest();

  const result = await runBoundedProcess(ctx.deps, {
    name: 'the listing',
    argv: ['sh', '-c', 'pwd; echo "$GREETING"'],
    timeoutMs: 2000,
    cwd: '/',
    env: { GREETING: 'hi', PATH: process.env['PATH'] ?? '' },
  });

  expect(result).toStrictEqual({ exitCode: 0, stdout: '/\nhi\n', stderr: '' });
});

test('it names the step, its elapsed time, the parts it waits on and its output when the process outlives its bound', async () => {
  const ctx = await setupTest();

  const ready = join(ctx.directory, 'ready');

  const running = runBoundedProcess(ctx.deps, {
    name: 'the stalled step',
    argv: ['sh', '-c', `echo partial; echo stuck >&2; touch ${ready}; exec sleep 5`],
    timeoutMs: 2000,
  });

  await waitForCondition(() => existsSync(ready));

  ctx.clock.now = 3000;

  ctx.deadline.resolve();

  expect(running).rejects.toThrowWithMessage(
    Error,
    'the stalled step did not finish within 2000 ms (stopped after 2000 ms, waiting on exit, stdout, stderr); stdout: partial\n; stderr: stuck\n',
  );
});

test('it stops at its bound, waiting on the pipes alone, when a grandchild keeps them open after the process ends', async () => {
  const ctx = await setupTest();

  const pidFile = join(ctx.directory, 'child.pid');

  const running = runBoundedProcess(ctx.deps, {
    name: 'the step with a straggler',
    argv: ['sh', '-c', `sleep 5 & echo $$ > ${pidFile}.tmp; mv ${pidFile}.tmp ${pidFile}; exit 0`],
    timeoutMs: 2000,
  });

  await waitForCondition(() => existsSync(pidFile));

  const pidText = await Bun.file(pidFile).text();

  const childPID = Number(pidText.trim());

  // Bun reaps the child, and settles its exit, before its process entry goes
  await waitForCondition(() => !existsSync(`/proc/${String(childPID)}`), { timeoutMs: 1000 });

  ctx.deadline.resolve();

  expect(running).rejects.toThrowWithMessage(
    Error,
    'the step with a straggler did not finish within 2000 ms (stopped after 0 ms, waiting on stdout, stderr); stdout: ; stderr: ',
  );
});

test('it waits for the killed process to exit before it rejects', async () => {
  const ctx = await setupTest();

  const pidFile = join(ctx.directory, 'child.pid');

  const running = runBoundedProcess(ctx.deps, {
    name: 'the stalled step',
    argv: ['sh', '-c', `echo $$ > ${pidFile}.tmp; mv ${pidFile}.tmp ${pidFile}; exec sleep 5`],
    timeoutMs: 2000,
  });

  await waitForCondition(() => existsSync(pidFile));

  const pidText = await Bun.file(pidFile).text();

  const childPID = Number(pidText.trim());

  ctx.deadline.resolve();

  await running.catch(() => null);

  expect(existsSync(`/proc/${String(childPID)}`)).toBeFalse();
});

test('it kills the grandchildren of a process that outlives its bound', async () => {
  const ctx = await setupTest();

  const pidFile = join(ctx.directory, 'grandchild.pid');

  const running = runBoundedProcess(ctx.deps, {
    name: 'the step with a grandchild',
    argv: ['sh', '-c', `sleep 5 & echo $! > ${pidFile}.tmp; mv ${pidFile}.tmp ${pidFile}; wait`],
    timeoutMs: 2000,
  });

  await waitForCondition(() => existsSync(pidFile));

  const pidText = await Bun.file(pidFile).text();

  const grandchildPID = Number(pidText.trim());

  ctx.deadline.resolve();

  await running.catch(() => null);

  // init reaps the orphaned grandchild after the kill, so its process entry goes a moment later
  await waitForCondition(() => !existsSync(`/proc/${String(grandchildPID)}`), { timeoutMs: 1000 });

  expect(existsSync(`/proc/${String(grandchildPID)}`)).toBeFalse();
});
