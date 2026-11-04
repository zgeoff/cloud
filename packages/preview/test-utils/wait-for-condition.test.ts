import { expect, test } from 'bun:test';
import { waitForCondition } from './wait-for-condition.ts';

test('it resolves once the condition holds', async () => {
  const state = { ready: false };

  setTimeout(() => {
    state.ready = true;
  }, 30);

  await waitForCondition(() => state.ready);

  expect(state.ready).toBe(true);
});

test('it fails when the condition never holds before the timeout', () => {
  expect(waitForCondition(() => false, { timeoutMs: 50 })).rejects.toThrow(
    'the condition did not hold before the wait timed out',
  );
});

test('it resolves once an async condition resolves true', async () => {
  const state = { ready: false };

  setTimeout(() => {
    state.ready = true;
  }, 30);

  await waitForCondition(() => Promise.resolve(state.ready));

  expect(state.ready).toBe(true);
});
