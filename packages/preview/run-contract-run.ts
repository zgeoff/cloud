import { buildContractStatus } from './build-contract-status.ts';
import type { ContractOutcome, ContractRun, ContractRunKey } from './create-preview-store.ts';
import { runContractSuite } from './run-contract-suite.ts';
import type { ContractSettings, PreviewDeps } from './types.ts';

const contractStatusContext = 'sdk-contract';

export async function runContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  const contract = deps.settings.contract;

  if (contract === null || deps.store.findContractRun(key)?.phase === 'settling') {
    await (contract === null ? stopContractRun(deps, key) : trySettleContractRun(deps, key));

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

async function stopContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  deps.store.updateContractPhase(key, ['queued', 'waiting', 'running'], {
    phase: 'settling',
    detail: 'The SDK contract run is off on this service',
    outcome: 'error',
  });

  await trySettleContractRun(deps, key);
}

interface Status {
  readonly state: 'pending' | ContractOutcome;
  readonly description: string;
}

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
    // the imp goes before the status, so a run whose status reads done holds no imp
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

    // ends the run rather than retry against an impd that refused it
    await applyContractStatus(deps, run, {
      state: 'error',
      description: `The run's imp did not start: ${reason}`,
    });

    return null;
  }
}

const fullSlots: Status = { state: 'pending', description: 'Waiting for a free preview slot' };

async function startContractImp(
  deps: PreviewDeps,
  contract: ContractSettings,
  run: ContractRun,
): Promise<ContractRun | null> {
  const imps = await deps.impd.readImps();

  // a preview's imp and another run's hold a slot alike, and a run never puts a preview to sleep
  // to take one, because the owner may be using it
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

async function updateContractWaiting(deps: PreviewDeps, run: ContractRun): Promise<void> {
  const waiting = { phase: 'waiting', detail: fullSlots.description } as const;

  // only the first try that finds the slots full says so, so a retry posts nothing new
  if (deps.store.updateContractPhase(run, ['queued'], waiting)) {
    await sendContractStatus(deps, run, fullSlots);
  }
}

interface ContractImp extends ContractRun {
  // impd holds an imp of the run's name, which a stopped service left behind
  readonly existing: boolean;
}

async function createContractImp(
  deps: PreviewDeps,
  contract: ContractSettings,
  imp: ContractImp,
): Promise<void> {
  // a left-behind imp goes first, so every run starts on a clean disk
  await (imp.existing ? deps.impd.removeImp(imp.imp) : Promise.resolve());

  // impd needs an HTTP port for each imp, though nothing in a run's imp listens on it
  await deps.impd.createImp({
    name: imp.imp,
    image: deps.settings.impImage,
    memoryMib: deps.settings.impMemoryMib,
    httpPort: 8080,
  });

  // the model secret's grant is the broker's model route
  await deps.impd.installGrant(imp.imp, contract.modelSecret);

  // the GitHub secret's grant lets the fetch reach a private repository
  if (deps.settings.impGitHubSecret !== null) {
    await deps.impd.installGrant(imp.imp, deps.settings.impGitHubSecret);
  }
}

async function removeContractImp(deps: PreviewDeps, imp: string): Promise<void> {
  const existing = await deps.impd.findImp(imp);

  await (existing === null ? Promise.resolve() : deps.impd.removeImp(imp));
}

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
    // the run goes on, since the result's status replaces a refused pending one
    deps.log(`${run.repo}@${run.headSHA}: the commit status was not set: ${String(error)}`);
  }
}
