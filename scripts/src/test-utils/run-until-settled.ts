import type { FakeClock } from '@zgeoff/testing/clock';

// runClockUntil's idle limit trips on the job's real file I/O between two sleeps, so this loop
// waits a real millisecond per turn and gives up only at maxMs of fake time.
export async function runUntilSettled<T>(
  clock: FakeClock,
  job: Promise<T>,
  options: Readonly<{ maxMs: number }>,
): Promise<T> {
  const state: { outcome: PromiseSettledResult<T> | null } = { outcome: null };

  const watch = async (): Promise<void> => {
    try {
      state.outcome = { status: 'fulfilled', value: await job };
    } catch (error) {
      state.outcome = { status: 'rejected', reason: error };
    }
  };

  const watching = watch();
  const limitMs = clock.now() + options.maxMs;

  while (state.outcome === null) {
    await Bun.sleep(1);

    const nextDueMs = clock.readNextDueMs();

    if (nextDueMs !== null && state.outcome === null) {
      if (nextDueMs > limitMs) {
        throw new Error('the job did not settle within the fake time limit');
      }

      clock.advance(nextDueMs - clock.now());
    }
  }

  await watching;

  if (state.outcome.status === 'rejected') {
    throw state.outcome.reason;
  }

  return state.outcome.value;
}
