import { contractImpPrefix } from './build-contract-imp-name.ts';
import type { ImpActivity } from './plan-slot-evictions.ts';

export function planIdleSleeps(imps: readonly ImpActivity[], idleMs: number, now: Date): string[] {
  // impd counts a request through its wake proxy as use, and an imp's creation as its first. A
  // contract run's suite never uses the wake proxy, so its imp would look idle.
  return imps
    .filter(
      (imp) =>
        imp.state === 'running' &&
        !imp.name.startsWith(contractImpPrefix) &&
        now.getTime() - imp.lastActiveAt.getTime() >= idleMs,
    )
    .map((imp) => imp.name);
}
