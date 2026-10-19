import type { ContractRun } from './create-preview-store.ts';
import type { ContractSettings, PreviewDeps } from './types.ts';

interface CommandResult {
  readonly code: number | null;
  readonly output: string;
}

// Runs the SDK contract suite in the run's imp and returns the guest command's result, or null
// when the host's deadline passes first. The guest's `timeout` bounds the run, and the deadline
// backs it for a guest that never reports an exit.
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

interface GuestCommand {
  readonly imp: string;
  readonly argv: readonly string[];
  readonly signal: AbortSignal;
}

// impd refuses to start the command unless the broker reaches the guest, so the suite never runs
// without its model route. An exec that breaks reads as a command that a signal ended.
async function tryRunGuestCommand(
  deps: PreviewDeps,
  command: GuestCommand,
): Promise<CommandResult> {
  try {
    return await deps.impd.runCommand(command.imp, command.argv, {
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

// How long past the guest's own bound the host waits: the guest's kill after its bound, and the
// time impd takes to report the exit
const deadlineGraceMs = 90_000;

async function waitForDeadline(deps: PreviewDeps, delayMs: number): Promise<null> {
  await deps.sleep(delayMs);

  return null;
}
