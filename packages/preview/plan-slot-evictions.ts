import type { Imp } from '@zgeoff/imp-client';
import { contractImpPrefix } from './build-contract-imp-name.ts';

// The part of impd's record of an imp that the slot and idle rules read. impd sets lastActiveAt
// when it creates the imp, and moves it on each use.
export type ImpActivity = Readonly<Pick<Imp, 'name' | 'state' | 'lastActiveAt'>>;

// The previews to put to sleep, least recently active first, so the opening one fits `slots`
// running imps. A contract run's imp holds a slot but never sleeps, since its suite would stop
// halfway, so the opening preview may run beside it.
export function planSlotEvictions(
  imps: readonly ImpActivity[],
  slots: number,
  opening: string,
): string[] {
  const live = imps.filter((imp) => imp.name !== opening && imp.state === 'running');

  const previews = live
    .filter((imp) => !imp.name.startsWith(contractImpPrefix))
    .toSorted((a, b) => a.lastActiveAt.getTime() - b.lastActiveAt.getTime());

  return previews.slice(0, Math.max(0, live.length - (slots - 1))).map((imp) => imp.name);
}
