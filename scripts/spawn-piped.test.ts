import { expect, test } from 'bun:test';
import { spawnPiped } from './spawn-piped.ts';

test('it gives the process output on its pipes and its exit code', async () => {
  const spawned = spawnPiped(['bash', '-c', 'echo listening; echo refused >&2; exit 3']);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(spawned.stdout).text(),
    new Response(spawned.stderr).text(),
    spawned.exited,
  ]);

  expect({ stdout, stderr, exitCode }).toStrictEqual({
    stdout: 'listening\n',
    stderr: 'refused\n',
    exitCode: 3,
  });
});

test('it ends a process that it kills with SIGTERM', async () => {
  const spawned = spawnPiped(['sleep', '30']);

  spawned.kill();

  const exitCode = await spawned.exited;

  expect(exitCode).toBe(143);
});
