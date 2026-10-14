import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from './run-process.ts';

test('it passes each argv element to the program whole, with no shell to split or expand it', async () => {
  const result = await runProcess(['printf', '%s|', 'two words', '$HOME', '*', "it's"]);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from("two words|$HOME|*|it's|"),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it gives the program the stdin buffer whole, NUL bytes included', async () => {
  const result = await runProcess(['od', '-An', '-c'], { stdin: Buffer.from('a\0b\n') });

  expect(result.stdout.toString().trim()).toBe(String.raw`a  \0   b  \n`);
});

test('it gives the program an empty stdin without a buffer', async () => {
  const result = await runProcess(['wc', '-c']);

  expect(result.stdout.toString().trim()).toBe('0');
});

test('it returns the exit code and stderr of a program that fails', async () => {
  const result = await runProcess(['bash', '-c', 'echo out; echo err >&2; exit 3']);

  expect(result).toStrictEqual({
    exitCode: 3,
    stdout: Buffer.from('out\n'),
    stderr: Buffer.from('err\n'),
    timedOut: false,
  });
});

test('it exits 127 for a program that is not installed', async () => {
  const result = await runProcess(['run-process-test-no-such-program']);

  expect(result.exitCode).toBe(127);
  expect(result.stderr.toString()).toStartWith('run-process-test-no-such-program: ');
  expect(result.timedOut).toBe(false);
});

test('it stops a program that outlives its timeout with SIGTERM', async () => {
  const result = await runProcess(['tail', '-f', '/dev/null'], { timeoutMs: 50 });

  expect(result.exitCode).toBe(143);
  expect(result.timedOut).toBe(true);
});

test('it stops a program with SIGTERM when its signal aborts, and reports no timeout', async () => {
  const controller = new AbortController();

  const running = runProcess(['tail', '-f', '/dev/null'], { signal: controller.signal });

  controller.abort();

  const result = await running;

  expect(result.exitCode).toBe(143);
  expect(result.timedOut).toBe(false);
});

test('it stops a program that ignores SIGTERM with SIGKILL when its forceStop aborts', async () => {
  const controller = new AbortController();

  const running = runProcess(['bash', '-c', 'trap "" TERM; while :; do sleep 0.05; done'], {
    forceStop: controller.signal,
  });

  controller.abort();

  const result = await running;

  expect(result.exitCode).toBe(137);
  expect(result.timedOut).toBe(false);
});

test('it reports a program that dies of its own SIGTERM as no timeout', async () => {
  const result = await runProcess(['bash', '-c', 'kill -TERM $$'], { timeoutMs: 60_000 });

  expect(result.exitCode).toBe(143);
  expect(result.timedOut).toBe(false);
});

test('it runs the program in the directory and with only the environment it names', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'run-process-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const result = await runProcess(['bash', '-c', 'pwd; env | sort'], {
    cwd: dir,
    env: { PATH: process.env['PATH'], RUN_PROCESS_TEST: 'set' },
  });

  const lines = result.stdout.toString().split('\n');

  expect(lines[0]).toBe(dir);
  expect(lines).toIncludeAllMembers(['RUN_PROCESS_TEST=set']);
  expect(lines.filter((line) => line.startsWith('HOME='))).toStrictEqual([]);
});
