import { contractImpPrefix } from './build-contract-imp-name.ts';
import type { ImpActivity } from './plan-slot-evictions.ts';

interface ContractSlotRule {
  readonly slots: number;
  readonly idleMs: number;
  readonly now: Date;
}

export function planContractEvictions(
  imps: readonly ImpActivity[],
  run: string,
  rule: ContractSlotRule,
): string[] | null {
  const live = imps.filter((imp) => imp.name !== run && imp.state === 'running');
  const needed = live.length - (rule.slots - 1);

  if (needed <= 0) {
    return [];
  }

  // impd moves lastRequestAt while a proxied stream or WebSocket stays open, so a preview in use
  // never reads as idle; another run's imp never sleeps, as its suite would stop
  const idle = live
    .filter(
      (imp) =>
        !imp.name.startsWith(contractImpPrefix) &&
        rule.now.getTime() - imp.lastUsedAt.getTime() >= rule.idleMs,
    )
    .toSorted((left, right) => left.lastUsedAt.getTime() - right.lastUsedAt.getTime());

  return idle.length >= needed ? idle.slice(0, needed).map((imp) => imp.name) : null;
}
