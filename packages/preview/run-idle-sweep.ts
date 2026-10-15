import { planIdleSleeps } from './plan-idle-sleeps.ts';
import type { PreviewDeps } from './types.ts';

// One pass of the idle sweep, which the service runs on a timer: every running preview imp that
// went unused for the idle timeout goes to sleep. impd lists only the imps the service's token
// names, so the sweep never touches another imp. A failure is logged, and the next pass retries.
export async function runIdleSweep(deps: PreviewDeps): Promise<void> {
  try {
    const imps = await deps.impd.readImps();

    for (const name of planIdleSleeps(imps, deps.settings.idleMs, deps.now())) {
      // oxlint-disable-next-line no-await-in-loop -- one sleep at a time keeps impd's work bounded
      await deps.impd.sleepImp(name);

      deps.log(`${name}: asleep after the idle timeout`);
    }
  } catch (error) {
    deps.log(`the idle sweep failed: ${String(error)}`);
  }
}
