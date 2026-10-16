import { contractImpPrefix } from './build-contract-imp-name.ts';
import type { ImpActivity } from './plan-slot-evictions.ts';

// The running previews that no one used for `idleMs` before `now`, to put to sleep. impd counts a
// request through its wake proxy as use, and an imp with no recorded use yet counts as idle.
// A contract run's imp never sleeps, since its suite never uses the wake proxy.
export function planIdleSleeps(imps: readonly ImpActivity[], idleMs: number, now: Date): string[] {
  return imps
    .filter(
      (imp) =>
        imp.state === 'running' &&
        !imp.name.startsWith(contractImpPrefix) &&
        now.getTime() - (imp.lastActiveAt?.getTime() ?? 0) >= idleMs,
    )
    .map((imp) => imp.name);
}
