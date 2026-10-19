import { startContractRun } from './start-contract-run.ts';
import type { PreviewDeps } from './types.ts';

export function runContractRetries(deps: PreviewDeps): void {
  for (const run of deps.store.collectContractRuns(['queued', 'waiting', 'settling'])) {
    startContractRun(deps, run);
  }
}
