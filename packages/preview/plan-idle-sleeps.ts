import type { ImpActivity } from './plan-slot-evictions.ts';

// The running previews that no one used for `idleMs` before `now`, to put to sleep. impd counts a
// request through its wake proxy as use, so a preview open in a browser that still talks to it
// stays awake. An imp with no recorded use yet counts as idle.
export function planIdleSleeps(imps: readonly ImpActivity[], idleMs: number, now: Date): string[] {
  return imps
    .filter(
      (imp) =>
        imp.state === 'running' && now.getTime() - (imp.lastActiveAt?.getTime() ?? 0) >= idleMs,
    )
    .map((imp) => imp.name);
}
