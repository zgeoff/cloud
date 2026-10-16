import { startContractRun } from './start-contract-run.ts';
import type { PreviewDeps } from './types.ts';

// One pass of the contract retry, on the idle sweep's timer: every run that waits for a slot, that a
// stopped service left queued, or whose result still waits to settle gets another try. A try that
// finds the run already started, by the delivery that claimed it or by an earlier pass, leaves it.
export function runContractRetries(deps: PreviewDeps): void {
  for (const run of deps.store.collectContractRuns(['queued', 'waiting', 'settling'])) {
    startContractRun(deps, run);
  }
}
