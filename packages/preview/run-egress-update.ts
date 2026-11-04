import type { PreviewDeps } from './types.ts';

// An imp keeps the egress policy it was created with, so each start of the service puts every imp
// the token reaches under the public policy, a running preview included.
export async function runEgressUpdate(deps: PreviewDeps): Promise<void> {
  try {
    // impd lists only the token's imps
    const imps = await deps.impd.readImps();

    for (const imp of imps) {
      await tryUpdatePublicEgress(deps, imp.name);
    }
  } catch (error) {
    deps.log(`the egress update failed: ${String(error)}`);
  }
}

async function tryUpdatePublicEgress(deps: PreviewDeps, name: string): Promise<void> {
  try {
    await deps.impd.updatePublicEgress(name);
  } catch (error) {
    deps.log(`${name}: the egress update failed: ${String(error)}`);
  }
}
