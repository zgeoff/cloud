import { planSlotEvictions } from './plan-slot-evictions.ts';
import type { PreviewDeps } from './types.ts';

// Puts the least recently used running previews to sleep until the opening one fits the slots.
// Its caller holds the slot lock, so no other open plans against the same running imps.
export async function applySlotEvictions(deps: PreviewDeps, opening: string): Promise<void> {
  const imps = await deps.impd.readImps();

  const evictions = planSlotEvictions(imps, deps.settings.slots, opening);

  // a preview that will not sleep, such as one under a lease, keeps running beside the opening one
  for (const name of evictions) {
    try {
      await deps.impd.sleepImp(name);

      deps.log(`${name}: asleep to free a slot for ${opening}`);
    } catch (error) {
      deps.log(`${name}: could not sleep it to free a slot: ${String(error)}`);
    }
  }
}
