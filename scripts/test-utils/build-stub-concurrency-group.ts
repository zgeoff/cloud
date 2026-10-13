import type { ActionsConcurrency } from './parse-actions-workflow.ts';

// One GitHub Actions concurrency group, per GitHub's "Control the concurrency of workflows and
// jobs" on 2026-10-13: one holder runs at a time, and the others wait in the order they joined.
export interface StubConcurrencyGroup<Holder> {
  // starts the holder when nothing runs, and returns whether it started and whom the join cancelled
  readonly join: (holder: Holder) => JoinResult<Holder>;

  // ends the running holder, and starts and returns the next one that waits
  readonly finish: () => Holder | undefined;
}

export interface JoinResult<Holder> {
  readonly started: boolean;
  readonly cancelled: readonly Holder[];
}

// GitHub's cap on the holders that wait in a `queue: max` group
const maxPending = 100;

export function buildStubConcurrencyGroup<Holder>(
  queue: ActionsConcurrency['queue'],
): StubConcurrencyGroup<Holder> {
  let running = false;
  const pending: Holder[] = [];

  return {
    join: (holder) => {
      if (!running) {
        running = true;

        return { started: true, cancelled: [] };
      }

      return { started: false, cancelled: updatePending(pending, queue, holder) };
    },
    finish: () => {
      const next = pending.shift();

      running = next !== undefined;

      return next;
    },
  };
}

// `queue: single` drops the holder already waiting for the newcomer; `queue: max` keeps it, and
// drops the newcomer instead once the queue is full
function updatePending<Holder>(
  pending: Holder[],
  queue: ActionsConcurrency['queue'],
  holder: Holder,
): Holder[] {
  const cancelled = queue === 'single' ? pending.splice(0) : [];

  if (pending.length < maxPending) {
    pending.push(holder);
  } else {
    cancelled.push(holder);
  }

  return cancelled;
}
