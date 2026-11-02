import { contractScript } from './contract-script.ts';
import type { ContractRun } from './create-preview-store.ts';
import type { ContractSettings, PreviewDeps } from './types.ts';

interface CommandResult {
  readonly code: number | null;
  readonly output: string;
}

// How long past the guest's own bound the host waits: the guest's kill after its bound, and the
// time impd takes to report the exit
const deadlineGraceMs = 90_000;

export async function runContractSuite(
  deps: PreviewDeps,
  contract: ContractSettings,
  run: ContractRun,
): Promise<CommandResult | null> {
  const exec = new AbortController();

  const result = await Promise.race([
    tryRunGuestCommand(deps, {
      imp: run.imp,
      argv: buildContractArgv(contract, run),
      signal: exec.signal,
    }),

    // backs the guest's `timeout` for a guest that never reports an exit
    waitForDeadline(deps, contract.timeoutMs + deadlineGraceMs),
  ]);

  // a command the deadline outran stops, so its exec never outlives the run
  exec.abort();

  if (result !== null) {
    deps.log(
      `${run.repo}@${run.headSHA}: the SDK contract suite's output:\n${result.output.slice(-4000)}`,
    );
  }

  return result;
}

interface GuestCommand {
  readonly imp: string;
  readonly argv: readonly string[];
  readonly signal: AbortSignal;
}

async function tryRunGuestCommand(
  deps: PreviewDeps,
  command: GuestCommand,
): Promise<CommandResult> {
  try {
    return await deps.impd.runCommand(command.imp, command.argv, {
      // impd refuses to start the command unless the broker reaches the guest, so the suite never
      // runs without its model route
      requireBroker: true,
      signal: command.signal,
    });
  } catch (error) {
    return {
      code: null,
      output: `the exec failed: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

// The guest holds this where the CLI reads its credential, and the model secret's grant replaces
// the authorization header on each request to the model's API
const modelPlaceholder = 'imp-broker-placeholder';

function buildContractArgv(contract: ContractSettings, run: ContractRun): string[] {
  return [
    'timeout',
    '--kill-after=30',
    String(Math.ceil(contract.timeoutMs / 1000)),
    'env',
    `ANTHROPIC_AUTH_TOKEN=${modelPlaceholder}`,
    'sh',
    '-c',
    contractScript,
    'sdk-contract',
    run.repo,
    run.headSHA,
  ];
}

async function waitForDeadline(deps: PreviewDeps, delayMs: number): Promise<null> {
  await deps.sleep(delayMs);

  return null;
}
