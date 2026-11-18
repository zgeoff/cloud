import { expect, test } from 'bun:test';
import { probeAlive } from './probe-alive.ts';

test('it reports a running process as alive', () => {
  expect(probeAlive(process.pid)).toBe(true);
});

test('it reports a reaped process as gone', async () => {
  const child = Bun.spawn(['true']);

  await child.exited;

  expect(probeAlive(child.pid)).toBe(false);
});
