import { planIdleSleeps } from './plan-idle-sleeps.ts';
import type { PreviewDeps } from './types.ts';

// One pass of the idle sweep, on a timer: every running preview imp unused for the idle timeout
// sleeps. impd lists only the token's imps, and the slot lock keeps the sweep out of a running
// boot's imp. A failure is logged, a refused sleep never stops the others, and the next pass retries.
export async function runIdleSweep(deps: PreviewDeps): Promise<void> {
  await deps.withSlotLock(() => trySleepIdlePreviews(deps));
}

async function trySleepIdlePreviews(deps: PreviewDeps): Promise<void> {
  try {
    const imps = await deps.impd.readImps();

    for (const name of planIdleSleeps(imps, deps.settings.idleMs, deps.now())) {
      // oxlint-disable-next-line no-await-in-loop -- one sleep at a time keeps impd's work bounded
      await trySleepImp(deps, name);
    }
  } catch (error) {
    deps.log(`the idle sweep failed: ${String(error)}`);
  }
}

async function trySleepImp(deps: PreviewDeps, name: string): Promise<void> {
  try {
    await deps.impd.sleepImp(name);

    deps.log(`${name}: asleep after the idle timeout`);
  } catch (error) {
    deps.log(`${name}: the idle sleep failed: ${String(error)}`);
  }
}
