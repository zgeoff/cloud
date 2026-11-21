import { expect, test } from 'bun:test';
import { createFakeClock } from '@zgeoff/testing/clock';
import { runUntilSettled } from './run-until-settled.ts';

test('it steps the clock through each sleep and returns the result of the job', async () => {
  const clock = createFakeClock();

  const job = (async () => {
    await clock.sleep(5000);
    await clock.sleep(5000);

    return 'done';
  })();

  const result = await runUntilSettled(clock, job, { maxMs: 60_000 });

  expect(result).toBe('done');
  expect(clock.now()).toBe(10_000);
});

test('it throws the error of the job', () => {
  const clock = createFakeClock();

  const job = (async () => {
    await clock.sleep(1000);

    throw new Error('the job failed');
  })();

  const outcome = runUntilSettled(clock, job, { maxMs: 60_000 });

  expect(outcome).rejects.toThrow('the job failed');
});

test('it throws when the job still waits at the fake time limit', () => {
  const clock = createFakeClock();
  const outcome = runUntilSettled(clock, clock.sleep(120_000), { maxMs: 60_000 });

  expect(outcome).rejects.toThrow('the job did not settle within the fake time limit');
});
