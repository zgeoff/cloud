import type { PreviewDeps } from './types.ts';

// long enough for impd to come back from a restart, short enough that the model route listener,
// which opens only after the update, stays closed for seconds
const retryMs = 5000;

// An imp keeps the egress policy it was created with, so each start of the service puts every imp
// the token reaches under the public policy, a running preview included. It tries again until
// every imp has it, and returns false only when the signal stops it first.
export async function runEgressUpdate(deps: PreviewDeps, signal: AbortSignal): Promise<boolean> {
  while (!signal.aborted) {
    const isUpdated = await tryUpdateEveryImp(deps);

    if (isUpdated) {
      return true;
    }

    await deps.sleep(retryMs);
  }

  return false;
}

async function tryUpdateEveryImp(deps: PreviewDeps): Promise<boolean> {
  try {
    // impd lists only the token's imps
    const imps = await deps.impd.readImps();

    const updated: boolean[] = [];

    for (const imp of imps) {
      const isUpdated = await tryUpdatePublicEgress(deps, imp.name);

      updated.push(isUpdated);
    }

    return updated.every(Boolean);
  } catch (error) {
    deps.log(`the egress update failed: ${String(error)}`);

    return false;
  }
}

async function tryUpdatePublicEgress(deps: PreviewDeps, name: string): Promise<boolean> {
  try {
    await deps.impd.updatePublicEgress(name);

    return true;
  } catch (error) {
    deps.log(`${name}: the egress update failed: ${String(error)}`);

    return false;
  }
}
