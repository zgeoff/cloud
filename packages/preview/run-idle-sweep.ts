import { planIdleSleeps } from './plan-idle-sleeps.ts';
import type { PreviewDeps } from './types.ts';

export async function runIdleSweep(deps: PreviewDeps): Promise<void> {
  // a running boot's guest commands would wake an imp the sweep put to sleep
  await deps.withSlotLock(() => trySleepIdlePreviews(deps));
}

async function trySleepIdlePreviews(deps: PreviewDeps): Promise<void> {
  try {
    // impd lists only the token's imps
    const imps = await deps.impd.readImps();

    for (const name of planIdleSleeps(imps, deps.settings.idleMs, deps.now())) {
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
