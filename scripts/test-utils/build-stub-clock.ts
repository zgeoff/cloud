export interface StubClock {
  readonly now: () => number;

  // returns at once, and moves the clock on by the time it was asked to wait
  readonly sleep: (delayMs: number) => Promise<void>;
  readonly sleeps: readonly number[];
}

export function buildStubClock(startMs: number): StubClock {
  const sleeps: number[] = [];
  let nowMs = startMs;

  return {
    now: () => nowMs,
    sleep: (delayMs) => {
      sleeps.push(delayMs);

      nowMs += delayMs;

      return Promise.resolve();
    },
    sleeps,
  };
}
