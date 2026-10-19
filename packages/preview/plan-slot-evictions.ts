import type { Imp } from '@impz/client';
import { contractImpPrefix } from './build-contract-imp-name.ts';

// impd sets lastActiveAt when it creates the imp, and moves it on each use.
export type ImpActivity = Readonly<Pick<Imp, 'name' | 'state' | 'lastActiveAt'>>;

export function planSlotEvictions(
  imps: readonly ImpActivity[],
  slots: number,
  opening: string,
): string[] {
  const live = imps.filter((imp) => imp.name !== opening && imp.state === 'running');

  // a contract run's imp holds a slot but never sleeps, since its suite would stop halfway
  const previews = live
    .filter((imp) => !imp.name.startsWith(contractImpPrefix))
    .toSorted((left, right) => left.lastActiveAt.getTime() - right.lastActiveAt.getTime());

  return previews.slice(0, Math.max(0, live.length - (slots - 1))).map((imp) => imp.name);
}
