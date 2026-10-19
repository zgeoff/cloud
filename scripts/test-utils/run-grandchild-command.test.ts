import { expect, test } from 'bun:test';
import { runProcess } from '../run-process.ts';
import { probeAlive } from './probe-alive.ts';
import { runGrandchildCommand } from './run-grandchild-command.ts';
import { waitForExit } from './wait-for-exit.ts';

test('it returns the pid of a grandchild that still runs', async () => {
  const pid = await runGrandchildCommand(runProcess, '');

  expect(probeAlive(pid)).toBe(true);
});

test('it runs the prelude in the grandchild first', async () => {
  const pid = await runGrandchildCommand(runProcess, 'trap "" TERM; ');

  process.kill(pid, 'SIGTERM');

  const isExited = await waitForExit(pid);

  expect(isExited).toBe(false);
});
