import type { ActionsConcurrency } from './parse-actions-workflow.ts';

// One GitHub Actions concurrency group, per GitHub's "Control the concurrency of workflows and
// jobs" on 2026-10-13: one holder runs at a time, and the others wait in the order they joined.
export interface StubConcurrencyGroup<Holder> {
  // starts the holder when nothing runs, and returns whether it started and whom the join cancelled
  readonly join: (holder: Holder) => JoinResult<Holder>;

  // ends the running holder, and starts and returns the next one that waits
  readonly finish: () => Holder | undefined;
}

interface JoinResult<Holder> {
  readonly started: boolean;
  readonly cancelled: readonly Holder[];
}

export function buildStubConcurrencyGroup<Holder>(
  queue: ActionsConcurrency['queue'],
): StubConcurrencyGroup<Holder> {
  let running = false;
  let pending: readonly Holder[] = [];

  return {
    join: (holder) => {
      if (!running) {
        running = true;

        return { started: true, cancelled: [] };
      }

      const planned = planJoin(pending, queue, holder);

      pending = planned.pending;

      return { started: false, cancelled: planned.cancelled };
    },
    finish: () => {
      const next = pending.at(0);

      pending = pending.slice(1);
      running = next !== undefined;

      return next;
    },
  };
}

interface PlannedJoin<Holder> {
  readonly pending: readonly Holder[];
  readonly cancelled: readonly Holder[];
}

// GitHub's cap on the holders that wait in a `queue: max` group
const maxPending = 100;

// `queue: single` drops the holder already waiting for the newcomer; `queue: max` keeps it, and
// drops the newcomer instead once the queue is full
function planJoin<Holder>(
  pending: readonly Holder[],
  queue: ActionsConcurrency['queue'],
  holder: Holder,
): PlannedJoin<Holder> {
  const kept = queue === 'single' ? [] : pending;
  const cancelled = queue === 'single' ? pending : [];

  if (kept.length >= maxPending) {
    return { pending: kept, cancelled: [...cancelled, holder] };
  }

  return { pending: [...kept, holder], cancelled };
}
