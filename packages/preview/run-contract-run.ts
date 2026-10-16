import { buildContractStatus } from './build-contract-status.ts';
import type { ContractOutcome, ContractRun, ContractRunKey } from './create-preview-store.ts';
import { runContractSuite } from './run-contract-suite.ts';
import type { ContractSettings, PreviewDeps } from './types.ts';

// The commit status context that each run sets on its head commit
export const contractStatusContext = 'sdk-contract';

// One try at a claimed run of the SDK contract suite: with a free preview slot, it runs the suite
// in a new imp at the head commit, removes the imp, and sets the commit status to the result.
// With every slot taken, the run waits, and the next retry tries it again.
export async function runContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  const contract = deps.settings.contract;

  if (contract === null || deps.store.findContractRun(key)?.phase === 'settling') {
    await trySettleContractRun(deps, key);

    return;
  }

  // the slot rule and the idle sweep never put a run's imp to sleep, so only its start holds the
  // slot lock, and its guest command runs after
  const run = await deps.withSlotLock(() => tryStartContractImp(deps, contract, key));

  if (run === null) {
    return;
  }

  const result = await runContractSuite(deps, contract, run);

  await applyContractStatus(deps, run, buildContractStatus(result, contract.timeoutMs));
}

interface Status {
  readonly state: 'pending' | ContractOutcome;
  readonly description: string;
}

// The result waits in the store until the imp is gone and GitHub holds the status, so a refused
// removal or status leaves the run settling, and the next retry settles it again
async function applyContractStatus(
  deps: PreviewDeps,
  run: ContractRun,
  status: Status & { readonly state: ContractOutcome },
): Promise<void> {
  deps.store.updateContractPhase(run, ['queued', 'waiting', 'running'], {
    phase: 'settling',
    detail: status.description,
    outcome: status.state,
  });

  await trySettleContractRun(deps, run);
}

// The imp goes before the status says the run ended, so a run whose status reads done holds no imp
async function trySettleContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  const run = deps.store.findContractRun(key);

  if (run?.phase !== 'settling' || run.outcome === null) {
    return;
  }

  const ended = {
    phase: run.outcome === 'success' ? 'passed' : 'failed',
    detail: run.detail ?? '',
    outcome: run.outcome,
  } as const;

  try {
    await removeContractImp(deps, run.imp);

    await deps.github.updateCommitStatus({
      repo: run.repo,
      sha: run.headSHA,
      context: contractStatusContext,
      state: run.outcome,
      description: ended.detail,
    });

    deps.store.updateContractPhase(run, ['settling'], ended);
    deps.log(`${run.repo}@${run.headSHA}: the SDK contract run ended: ${ended.detail}`);
  } catch (error) {
    deps.log(`${run.repo}@${run.headSHA}: the next retry settles the run: ${String(error)}`);
  }
}

// The run's imp, started, or null when the run is not this try's to start or every slot is taken.
// A failure to start the imp ends the run with an error status, rather than retry against an impd
// that refused it.
async function tryStartContractImp(
  deps: PreviewDeps,
  contract: ContractSettings,
  key: ContractRunKey,
): Promise<ContractRun | null> {
  const run = deps.store.findContractRun(key);

  if (run === null || (run.phase !== 'queued' && run.phase !== 'waiting')) {
    return null;
  }

  try {
    return await startContractImp(deps, contract, run);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);

    await applyContractStatus(deps, run, {
      state: 'error',
      description: `The run's imp did not start: ${reason}`,
    });

    return null;
  }
}

const fullSlots: Status = { state: 'pending', description: 'Waiting for a free preview slot' };

// Every running imp the token lists holds a slot, a preview's and another run's alike. A run never
// puts a preview to sleep to take its slot, because the owner may be using it.
async function startContractImp(
  deps: PreviewDeps,
  contract: ContractSettings,
  run: ContractRun,
): Promise<ContractRun | null> {
  const imps = await deps.impd.readImps();

  const running = imps.filter((imp) => imp.state === 'running' && imp.name !== run.imp);

  if (running.length >= deps.settings.slots) {
    await updateContractWaiting(deps, run);

    return null;
  }

  await createContractImp(deps, contract, {
    ...run,
    existing: imps.some((imp) => imp.name === run.imp),
  });

  deps.store.updateContractPhase(run, ['queued', 'waiting'], { phase: 'running' });

  await sendContractStatus(deps, run, {
    state: 'pending',
    description: 'Running the SDK contract suite',
  });

  return run;
}

// Only the first try that finds the slots full says so, so a retry posts nothing new
async function updateContractWaiting(deps: PreviewDeps, run: ContractRun): Promise<void> {
  const waiting = { phase: 'waiting', detail: fullSlots.description } as const;

  if (deps.store.updateContractPhase(run, ['queued'], waiting)) {
    await sendContractStatus(deps, run, fullSlots);
  }
}

interface ContractImp extends ContractRun {
  // impd holds an imp of the run's name, which a stopped service left behind
  readonly existing: boolean;
}

// A left-behind imp goes first, so every run starts on a clean disk. The model secret's grant is the
// broker's model route; the GitHub secret's, when the service has one, lets the fetch reach a
// private repository.
async function createContractImp(
  deps: PreviewDeps,
  contract: ContractSettings,
  imp: ContractImp,
): Promise<void> {
  await (imp.existing ? deps.impd.removeImp(imp.imp) : Promise.resolve());

  // impd needs an HTTP port for each imp, though nothing in a run's imp listens on it
  await deps.impd.createImp({
    name: imp.imp,
    image: deps.settings.impImage,
    memoryMib: deps.settings.impMemoryMib,
    httpPort: 8080,
  });

  await deps.impd.installGrant(imp.imp, contract.modelSecret);

  if (deps.settings.impGitHubSecret !== null) {
    await deps.impd.installGrant(imp.imp, deps.settings.impGitHubSecret);
  }
}

async function removeContractImp(deps: PreviewDeps, imp: string): Promise<void> {
  const existing = await deps.impd.findImp(imp);

  await (existing === null ? Promise.resolve() : deps.impd.removeImp(imp));
}

// A pending status that GitHub refuses is logged, and the run goes on, since the result's status
// replaces it
async function sendContractStatus(
  deps: PreviewDeps,
  run: ContractRun,
  status: Status,
): Promise<void> {
  try {
    await deps.github.updateCommitStatus({
      repo: run.repo,
      sha: run.headSHA,
      context: contractStatusContext,
      ...status,
    });
  } catch (error) {
    deps.log(`${run.repo}@${run.headSHA}: the commit status was not set: ${String(error)}`);
  }
}
