import type { ContractRunKey } from './create-preview-store.ts';
import { runContractRun } from './run-contract-run.ts';
import type { PreviewDeps } from './types.ts';

export function startContractRun(deps: PreviewDeps, key: ContractRunKey): void {
  // not awaited, because a run takes minutes and a webhook delivery must answer at once
  const run = tryRunContractRun(deps, key);

  deps.pendingRuns.add(run);
  void removeSettledRun(deps.pendingRuns, run);
}

async function tryRunContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  try {
    await runContractRun(deps, key);
  } catch (error) {
    deps.log(`${key.repo}@${key.headSHA}: the SDK contract run failed: ${String(error)}`);
  }
}

async function removeSettledRun(pending: Set<Promise<void>>, run: Promise<void>): Promise<void> {
  await run;

  pending.delete(run);
}
