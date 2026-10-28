import { expect, test } from 'bun:test';
import { processDeps } from './process-deps.ts';

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

test('it kills the process group that the spawned process leads', async () => {
  const child = processDeps.spawn(['sh', '-c', 'sleep 5 & wait'], {});

  processDeps.killGroup(child.pid);

  const exitCode = await child.exited;

  expect(exitCode).toBe(137);
});
