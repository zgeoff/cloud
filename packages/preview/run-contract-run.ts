import { buildContractStatus } from './build-contract-status.ts';
import type { ContractRun, ContractRunKey } from './create-preview-store.ts';
import type { ContractSettings, PreviewDeps } from './types.ts';

// The commit status context that each run sets on its head commit
export const contractStatusContext = 'sdk-contract';

// One try at a claimed run of the SDK contract suite: with a free preview slot, it runs the suite
// in a new imp at the head commit, sets the commit status to the result, and removes the imp.
// With every slot taken, the run waits, and the next retry tries it again.
export async function runContractRun(deps: PreviewDeps, key: ContractRunKey): Promise<void> {
  const contract = deps.settings.contract;

  if (contract === null) {
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
  readonly state: 'pending' | 'success' | 'failure' | 'error';
  readonly description: string;
}

// The imp goes before the status says the run ended, so a run whose status reads done holds no imp
async function applyContractStatus(
  deps: PreviewDeps,
  run: ContractRun,
  status: Status,
): Promise<void> {
  await tryRemoveImp(deps, run.imp);

  deps.store.updateContractPhase(run, ['queued', 'waiting', 'running'], {
    phase: status.state === 'success' ? 'passed' : 'failed',
    detail: status.description,
  });

  await sendContractStatus(deps, run, status);

  deps.log(`${run.repo}@${run.headSHA}: the SDK contract run ended: ${status.description}`);
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

// Bun's linux-x64 build from its npm package, because imp's base image has tar but no unzip for the
// release zip. It is the version the suite's repository names as its package manager, and the
// sha256 is the tarball's own, which matches npm's published integrity.
const bunURL = 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-1.4.2.tgz';
const bunSHA256 = '0c75e0b94e9d56cece77abb7d03e9995b47b79506df5dcca3046eeb888db5934';

// The guest script takes the repository and the commit as arguments, never inside its text. Each
// run's imp is new, so the script installs Bun and the dependencies every time.
const contractScript = `set -eu
mkdir -p /opt/bun/bin /srv/sdk-contract
curl -fsSL -o /opt/bun/bun.tgz ${bunURL}
echo "${bunSHA256}  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
tar -xzf /opt/bun/bun.tgz -C /opt/bun/bin --strip-components=2 package/bin/bun
export PATH="/opt/bun/bin:$PATH"
cd /srv/sdk-contract
git init -q
git remote add origin "https://github.com/$1.git"
git fetch -q --depth 1 origin "$2"
git checkout -q --force FETCH_HEAD
bun install --frozen-lockfile
NIXIE_SDK_CONTRACT=1 bun test evals/sdk-contract
`;

// The guest holds this where the CLI reads its credential, and the model secret's grant replaces
// the authorization header on each request to the model's API
const modelPlaceholder = 'imp-broker-placeholder';

// How long past the guest's own bound the host waits: the guest's kill after its bound, and the
// time impd takes to report the exit
const deadlineGraceMs = 90_000;

interface CommandResult {
  readonly code: number | null;
  readonly output: string;
}

// The guest's `timeout` bounds the run, and the host's deadline backs it for a guest that never
// reports an exit. The run's imp goes after either, which ends the command's socket.
async function runContractSuite(
  deps: PreviewDeps,
  contract: ContractSettings,
  run: ContractRun,
): Promise<CommandResult | null> {
  const seconds = String(Math.ceil(contract.timeoutMs / 1000));

  const argv = [
    'timeout',
    '--kill-after=30',
    seconds,
    'env',
    `ANTHROPIC_AUTH_TOKEN=${modelPlaceholder}`,
  ];

  const result = await Promise.race([
    tryRunGuestCommand(deps, run.imp, [
      ...argv,
      'sh',
      '-c',
      contractScript,
      'sdk-contract',
      run.repo,
      run.headSHA,
    ]),
    waitForDeadline(deps, contract.timeoutMs + deadlineGraceMs),
  ]);

  if (result !== null) {
    deps.log(
      `${run.repo}@${run.headSHA}: the SDK contract suite's output:\n${result.output.slice(-4000)}`,
    );
  }

  return result;
}

// impd refuses to start the command unless the broker reaches the guest, so the suite never runs
// without its model route. An exec that breaks reads as a command that a signal ended.
async function tryRunGuestCommand(
  deps: PreviewDeps,
  imp: string,
  argv: readonly string[],
): Promise<CommandResult> {
  try {
    return await deps.impd.runCommand(imp, argv, { requireBroker: true });
  } catch (error) {
    return {
      code: null,
      output: `the exec failed: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

async function waitForDeadline(deps: PreviewDeps, ms: number): Promise<null> {
  await deps.sleep(ms);

  return null;
}

async function tryRemoveImp(deps: PreviewDeps, imp: string): Promise<void> {
  try {
    const existing = await deps.impd.findImp(imp);

    await (existing === null ? Promise.resolve() : deps.impd.removeImp(imp));
  } catch (error) {
    deps.log(`${imp}: the run's imp was not removed: ${String(error)}`);
  }
}

// A status that GitHub refuses is logged, and the run goes on, since the suite's result stands
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
