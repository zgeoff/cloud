import { expect, test } from 'bun:test';
import { buildStubClock } from './build-stub-clock.ts';

test('it moves the clock on by each sleep and records the sleeps', async () => {
  const clock = buildStubClock(10_000);

  await clock.sleep(50_000);
  await clock.sleep(2500);

  expect(clock.now()).toBe(62_500);
  expect(clock.sleeps).toStrictEqual([50_000, 2500]);
});
