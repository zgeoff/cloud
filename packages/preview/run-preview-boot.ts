import { applySlotEvictions } from './apply-slot-evictions.ts';
import type { PhaseChange, Preview } from './create-preview-store.ts';
import type { PreviewContract } from './parse-preview-contract.ts';
import { parsePreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';

// Boots a preview of the pull request's head commit, or rebuilds the imp that runs an older one,
// and leaves it `ready` or `failed`. A preview that left `booting` meanwhile, because its pull
// request closed, stays as it is.
export async function runPreviewBoot(deps: PreviewDeps, preview: Preview): Promise<void> {
  // the whole boot holds the slot lock: its build's guest commands would wake an imp that another
  // open put to sleep while it ran
  const result = await deps.withSlotLock(() => tryRunBootSteps(deps, preview));

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

// A close that came before the imp existed found nothing to remove, so the boot removes the imp
// it started
async function checkClosedDuringBoot(
  deps: PreviewDeps,
  preview: Preview,
): Promise<PhaseChange | null> {
  if (deps.store.findPreview(preview)?.phase === 'booting') {
    return null;
  }

  await deps.impd.removeImp(preview.imp);

  return { phase: 'failed', detail: 'the pull request closed during the boot' };
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

  await startImpInSlot(deps, preview, contract);

  const closed = await checkClosedDuringBoot(deps, preview);

  return closed ?? runBuild(deps, preview, contract);
}

// Checks out the head commit and starts its stack in the imp, then waits for the health path. The
// guest's `timeout` bounds the build, which holds the slot lock, so a hung build fails its boot
// rather than block every other preview; it exits 124 when the bound passes.
async function runBuild(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<PhaseChange> {
  const seconds = String(Math.ceil(deps.settings.buildTimeoutMs / 1000));

  const build = await deps.impd.runCommand(
    preview.imp,
    [
      'timeout',
      '--kill-after=30',
      seconds,
      'sh',
      '-c',
      bootScript,
      'preview-boot',
      preview.repo,
      preview.headSHA,
    ],
    { requireBroker: deps.settings.impGitHubSecret !== null },
  );

  if (build.code !== 0) {
    const exit = build.code ?? 'on a signal';

    return { phase: 'failed', detail: `the build exited ${exit}:\n${build.output.slice(-4000)}` };
  }

  return waitForHealth(deps, preview, contract);
}

// Frees a slot, then starts the imp: the one from an earlier build, awake, with the port of the
// commit it rebuilds, or a new one with the contract's port and the GitHub grant. Only a preview
// that built once proves its imp got the grant, so an imp without a build is replaced.
async function startImpInSlot(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<void> {
  const imp = await deps.impd.findImp(preview.imp);

  await applySlotEvictions(deps, preview.imp);

  if (imp !== null && preview.builtSHA !== null) {
    await deps.impd.updateHTTPPort(preview.imp, contract.port);

    await (imp.state === 'running' ? Promise.resolve() : deps.impd.wakeImp(preview.imp));

    return;
  }

  await (imp === null ? Promise.resolve() : deps.impd.removeImp(preview.imp));
  await createPreviewImp(deps, preview, contract);
}

async function createPreviewImp(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<void> {
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
