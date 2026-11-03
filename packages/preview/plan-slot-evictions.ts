import type { Imp } from '@impz/client';
import { contractImpPrefix } from './build-contract-imp-name.ts';

export interface ImpActivity extends Readonly<Pick<Imp, 'name' | 'state'>> {
  // the last request through impd's wake proxy, or the imp's creation before the first; impd's
  // lastActiveAt also moves for the guest's own connections and CPU, so a stack never reads idle
  readonly lastUsedAt: Date;
}

export function planSlotEvictions(
  imps: readonly ImpActivity[],
  slots: number,
  opening: string,
): string[] {
  const live = imps.filter((imp) => imp.name !== opening && imp.state === 'running');

  // a contract run's imp holds a slot but never sleeps, since its suite would stop halfway
  const previews = live
    .filter((imp) => !imp.name.startsWith(contractImpPrefix))
    .toSorted((left, right) => left.lastUsedAt.getTime() - right.lastUsedAt.getTime());

  return previews.slice(0, Math.max(0, live.length - (slots - 1))).map((imp) => imp.name);
}
