import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runBoundedProcess } from './run-bounded-process.ts';
import { waitForCondition } from './wait-for-condition.ts';

test('it returns the exit code, stdout and stderr of a process that ends within its bound', async () => {
  const result = await runBoundedProcess({
    name: 'the greeting',
    argv: ['sh', '-c', 'echo hello; echo warning >&2; exit 3'],
    timeoutMs: 2000,
  });

  expect(result).toStrictEqual({ exitCode: 3, stdout: 'hello\n', stderr: 'warning\n' });
});

test('it runs the process in the given directory with the given environment', async () => {
  const result = await runBoundedProcess({
    name: 'the listing',
    argv: ['sh', '-c', 'pwd; echo "$GREETING"'],
    timeoutMs: 2000,
    cwd: '/',
    env: { GREETING: 'hi', PATH: process.env['PATH'] ?? '' },
  });

  expect(result).toStrictEqual({ exitCode: 0, stdout: '/\nhi\n', stderr: '' });
});

test('it names the step, its elapsed time and its stderr when the process outlives its bound', async () => {
  const result = await runBoundedProcess({
    name: 'the stalled step',
    argv: ['sh', '-c', 'echo stuck >&2; exec sleep 5'],
    timeoutMs: 200,
  }).then(
    () => null,
    (error: unknown) => error,
  );

  expect(result).toBeInstanceOf(Error);

  expect(String(result)).toSatisfy((message: string) =>
    /^Error: the stalled step did not finish within 200 ms \(stopped after \d+ ms\); stderr: stuck\n$/u.test(
      message,
    ),
  );
});

test('it stops at its bound when a grandchild keeps the pipes open after the process ends', async () => {
  const startedAt = performance.now();

  const result = await runBoundedProcess({
    name: 'the step with a straggler',
    argv: ['sh', '-c', 'sleep 5 & exit 0'],
    timeoutMs: 200,
  }).then(
    () => null,
    (error: unknown) => error,
  );

  expect(String(result)).toStartWith(
    'Error: the step with a straggler did not finish within 200 ms',
  );

  expect(performance.now() - startedAt).toBeLessThan(2000);
});

test('it kills the grandchildren of a process that outlives its bound', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bounded-process-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const pidFile = join(directory, 'grandchild.pid');

  await runBoundedProcess({
    name: 'the step with a grandchild',
    argv: ['sh', '-c', `sleep 5 & echo $! > ${pidFile}; wait`],
    timeoutMs: 200,
  }).catch(() => null);

  const pidText = await Bun.file(pidFile).text();

  const grandchildPID = Number(pidText.trim());

  await waitForCondition(() => !existsSync(`/proc/${String(grandchildPID)}`), {
    timeoutMs: 1000,
  });

  expect(existsSync(`/proc/${String(grandchildPID)}`)).toBeFalse();
});
