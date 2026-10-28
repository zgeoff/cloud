import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { processDeps } from './process-deps.ts';
import { waitForCondition } from './wait-for-condition.ts';

test('it spawns the process with piped stdout and stderr', async () => {
  const child = processDeps.spawn(['sh', '-c', 'echo out; echo err >&2; exit 4'], {});

  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);

  expect({ exitCode, stdout, stderr }).toStrictEqual({
    exitCode: 4,
    stdout: 'out\n',
    stderr: 'err\n',
  });
});

test('it lists the processes of the group that the spawned process leads, the leader with its command', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'process-deps-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const ready = join(directory, 'ready');
  const child = processDeps.spawn(['sh', '-c', `sleep 5 & touch ${ready}; wait`], {});

  onTestFinished(() => {
    processDeps.killGroup(child.pid);
  });

  await waitForCondition(() => existsSync(ready));

  const group = await processDeps.readGroup(child.pid);

  const lines = group.trimEnd().split('\n');

  expect(lines).toSatisfyAll((line: string) => line.split(/\s+/u)[1] === String(child.pid));

  expect(lines).toContainEqual(
    expect.toSatisfy(
      (line: string) =>
        line.split(/\s+/u)[0] === String(child.pid) && line.endsWith(`touch ${ready}; wait`),
    ),
  );
});

test('it kills the process group that the spawned process leads', async () => {
  const child = processDeps.spawn(['sh', '-c', 'sleep 5 & wait'], {});

  processDeps.killGroup(child.pid);

  const exitCode = await child.exited;

  expect(exitCode).toBe(137);
});
