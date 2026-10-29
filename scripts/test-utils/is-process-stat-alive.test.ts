import { expect, test } from 'bun:test';
import { isProcessStatAlive } from './is-process-stat-alive.ts';

test.each([
  ['a running', '4242 (sleep) R 4241 4242 4242 0 -1'],
  ['a sleeping', '4242 (sleep) S 4241 4242 4242 0 -1'],
])('it reads the stat of %s process as alive', (_, stat) => {
  expect(isProcessStatAlive(stat)).toBe(true);
});

test.each([
  ['a zombie', '4242 (sleep) Z 4241 4242 4242 0 -1'],
  ['a reaped but not yet removed', '4242 (sleep) X 0 4242 4242 0 -1'],
])('it reads the stat of %s process as exited', (_, stat) => {
  expect(isProcessStatAlive(stat)).toBe(false);
});

test('it reads the state after the last parenthesis of a command name that holds one', () => {
  expect(isProcessStatAlive('4242 (odd) S name) Z 4241 4242 4242 0 -1')).toBe(false);
});
