import type { PhaseChange, Preview } from './create-preview-store.ts';
import type { PreviewContract } from './parse-preview-contract.ts';
import { parsePreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';

// Boots a preview of the pull request's head commit, or rebuilds the imp that runs an older one,
// and leaves it `ready` or `failed`. A preview that left `booting` meanwhile, because its pull
// request closed, stays as it is.
export async function runPreviewBoot(deps: PreviewDeps, preview: Preview): Promise<void> {
  const result = await tryRunBootSteps(deps, preview);

  deps.store.updatePhase(preview, ['booting'], result);
  deps.log(`${preview.repo}#${preview.number}: ${result.phase} at ${preview.headSHA}`);
}

async function tryRunBootSteps(deps: PreviewDeps, preview: Preview): Promise<PhaseChange> {
  try {
    return await runBootSteps(deps, preview);
  } catch (error) {
    return { phase: 'failed', detail: error instanceof Error ? error.message : String(error) };
  }
}

// The guest script takes the repository and the commit as arguments, never inside its text. A
// rebuild takes the old stack down with its volumes first, so every build seeds fresh, invented
// data from the contract's seed step.
const bootScript = `set -eu
mkdir -p /srv/preview
cd /srv/preview
if [ ! -d .git ]; then
  git init -q
  git remote add origin "https://github.com/$1.git"
fi
if [ -f preview/compose.yaml ]; then
  (cd preview && docker compose down --volumes --remove-orphans) || true
fi
git fetch -q --depth 1 origin "$2"
git checkout -q --force FETCH_HEAD
cd preview
docker compose up --detach --build --wait
`;

async function runBootSteps(deps: PreviewDeps, preview: Preview): Promise<PhaseChange> {
  const compose = await deps.github.readComposeFile(preview.repo, preview.headSHA);

  if (compose === null) {
    return { phase: 'failed', detail: `preview/compose.yaml is gone at ${preview.headSHA}` };
  }

  const contract = parsePreviewContract(compose);

  await createOrUpdateImp(deps, preview, contract);

  const build = await deps.impd.runCommand(
    preview.imp,
    ['sh', '-c', bootScript, 'preview-boot', preview.repo, preview.headSHA],
    { requireBroker: deps.settings.impGitHubSecret !== null },
  );

  if (build.code !== 0) {
    const exit = build.code ?? 'on a signal';

    return { phase: 'failed', detail: `the build exited ${exit}:\n${build.output.slice(-4000)}` };
  }

  return waitForHealth(deps, preview, contract);
}

// A new imp gets the contract's port and the GitHub grant; an existing one, asleep or awake, takes
// the port of the commit it rebuilds
async function createOrUpdateImp(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<void> {
  const imp = await deps.impd.findImp(preview.imp);

  if (imp !== null) {
    await deps.impd.updateHTTPPort(preview.imp, contract.port);

    return;
  }

  await deps.impd.createImp({
    name: preview.imp,
    image: deps.settings.impImage,
    memoryMib: deps.settings.impMemoryMib,
    httpPort: contract.port,
  });

  if (deps.settings.impGitHubSecret !== null) {
    await deps.impd.createGrant(preview.imp, deps.settings.impGitHubSecret);
  }
}

// Polls the health path from inside the guest, so the probe needs no route to the imp
async function waitForHealth(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<PhaseChange> {
  const healthURL = `http://127.0.0.1:${contract.port}${contract.healthPath}`;
  const deadline = deps.now().getTime() + deps.settings.healthTimeoutMs;

  const probe = [
    'curl',
    '--fail',
    '--silent',
    '--output',
    '/dev/null',
    '--max-time',
    '5',
    healthURL,
  ];

  while (deps.now().getTime() < deadline) {
    // oxlint-disable-next-line no-await-in-loop -- each probe waits for the pause before it
    const answer = await deps.impd.runCommand(preview.imp, probe);

    if (answer.code === 0) {
      return { phase: 'ready', builtSHA: preview.headSHA };
    }

    // oxlint-disable-next-line no-await-in-loop -- the pause sits between two probes
    await deps.sleep(deps.settings.healthPollMs);
  }

  return { phase: 'failed', detail: `${healthURL} did not answer before the boot timed out` };
}
