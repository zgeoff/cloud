import { expect, onTestFinished, test } from 'bun:test';
import { readProcessStatus } from './read-process-status.ts';
import { waitForCondition } from './wait-for-condition.ts';

test('it reads a running process as running with no signal pending', () => {
  const child = Bun.spawn(['sleep', '30'], { stdin: 'ignore' });

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  expect(readProcessStatus(child.pid)).toStrictEqual({ stopped: false, pendingSignals: [] });
});

test('it reads a SIGTERM sent to a stopped process as pending', async () => {
  const child = Bun.spawn(['sleep', '30'], { stdin: 'ignore' });

  onTestFinished(() => {
    child.kill('SIGKILL');
  });

  process.kill(child.pid, 'SIGSTOP');

  await waitForCondition(() => readProcessStatus(child.pid).stopped);

  process.kill(child.pid, 'SIGTERM');

  expect(readProcessStatus(child.pid)).toStrictEqual({
    stopped: true,
    pendingSignals: ['SIGTERM'],
  });
});
