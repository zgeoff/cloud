import { applySlotEvictions } from './apply-slot-evictions.ts';
import type { PhaseChange, Preview } from './create-preview-store.ts';
import type { PreviewContract } from './parse-preview-contract.ts';
import { parsePreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';
import type { HealthResult } from './wait-for-healthy.ts';
import { waitForHealthy } from './wait-for-healthy.ts';

export async function runPreviewBoot(deps: PreviewDeps, preview: Preview): Promise<void> {
  // the whole boot holds the slot lock: its build's guest commands would wake an imp that another
  // open put to sleep while it ran
  const result = await deps.withSlotLock(() => tryRunBootSteps(deps, preview));

  deps.store.updatePhase(preview, ['booting'], pickSettledPhase(deps, preview, result));
  deps.log(`${preview.repo}#${preview.number}: ${result.phase} at ${preview.headSHA}`);
}

async function tryRunBootSteps(deps: PreviewDeps, preview: Preview): Promise<PhaseChange> {
  try {
    return await runBootSteps(deps, preview);
  } catch (error) {
    return { phase: 'failed', detail: error instanceof Error ? error.message : String(error) };
  }
}

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

async function startImpInSlot(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<void> {
  const imp = await deps.impd.readImp(preview.imp);

  await applySlotEvictions(deps, preview.imp);

  if (imp === null) {
    await deps.impd.createImp({
      name: preview.imp,
      image: deps.settings.impImage,
      memoryMib: deps.settings.impMemoryMib,
      httpPort: contract.port,
    });
  } else {
    await deps.impd.updateHTTPPort(preview.imp, contract.port);

    await (imp.state === 'running' ? Promise.resolve() : deps.impd.wakeImp(preview.imp));
  }

  // every boot installs the grants, so an imp whose grant failed or never came gets it now
  if (deps.settings.impGitHubSecret !== null) {
    await deps.impd.installGrant(preview.imp, deps.settings.impGitHubSecret);
  }

  if (deps.settings.impModelSecret === null) {
    return;
  }

  // with a counting proxy, the model secret's upstream is the service's route listener, and the
  // filter keeps each imp on its own route, so one preview can neither skip nor spend another's cap
  await (deps.spendProxies === null
    ? deps.impd.installGrant(preview.imp, deps.settings.impModelSecret)
    : deps.impd.installPathGrant(preview.imp, deps.settings.impModelSecret, [
        `/${preview.imp}/**`,
      ]));
}

async function checkClosedDuringBoot(
  deps: PreviewDeps,
  preview: Preview,
): Promise<PhaseChange | null> {
  if (deps.store.findPreview(preview)?.phase === 'booting') {
    return null;
  }

  // a close that came before the imp existed found nothing to remove
  await deps.impd.removeImp(preview.imp);

  return { phase: 'failed', detail: 'the pull request closed during the boot' };
}

// Docker Compose's release binary for the guests whose image lacks the plugin, such as imp's base
// image; its sha256 is the release's own, and apt's docker-compose-plugin ships the same bytes
const composeURL =
  'https://github.com/docker/compose/releases/download/v5.6.0/docker-compose-linux-x86_64';

const composeSHA256 = '40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a';

// The guest script takes the repository, the commit and the model route as arguments, never inside
// its text. A rebuild takes the old stack down with its volumes first, so every build seeds fresh
// data. A compose.broker.yaml joins with the proxy and CA bundle impd sets on an exec with a grant.
const bootScript = `set -eu
export PREVIEW_MODEL_ROUTE="$3"
if ! docker compose version >/dev/null 2>&1; then
  plugins=/usr/local/lib/docker/cli-plugins
  mkdir -p "$plugins"
  curl -fsSL -o "$plugins/docker-compose.part" ${composeURL}
  echo "${composeSHA256}  $plugins/docker-compose.part" | sha256sum -c - >/dev/null
  chmod 0755 "$plugins/docker-compose.part"
  mv "$plugins/docker-compose.part" "$plugins/docker-compose"
fi
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
if [ -f compose.broker.yaml ]; then
  export BROKER_CA_FILE="\${SSL_CERT_FILE:?the broker's CA bundle did not reach the boot}"
  docker compose -f compose.yaml -f compose.broker.yaml up --detach --build --wait
else
  docker compose up --detach --build --wait
fi
`;

async function runBuild(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<PhaseChange> {
  const seconds = String(Math.ceil(deps.settings.buildTimeoutMs / 1000));

  const build = await deps.impd.runCommand(
    preview.imp,
    [
      // the build holds the slot lock, so the bound fails a hung build's boot rather than block
      // every other preview; `timeout` exits 124 when the bound passes
      'timeout',
      '--kill-after=30',
      seconds,
      'sh',
      '-c',
      bootScript,
      'preview-boot',
      preview.repo,
      preview.headSHA,
      deps.spendProxies === null ? '' : preview.imp,
    ],
    { requireBroker: collectGrantSecrets(deps).length > 0 },
  );

  if (build.code !== 0) {
    const exit = build.code ?? 'on a signal';

    return { phase: 'failed', detail: `the build exited ${exit}:\n${build.output.slice(-4000)}` };
  }

  return waitForHealth(deps, preview, contract);
}

function collectGrantSecrets(deps: PreviewDeps): string[] {
  return [deps.settings.impGitHubSecret, deps.settings.impModelSecret].filter(
    (secret) => secret !== null,
  );
}

async function waitForHealth(
  deps: PreviewDeps,
  preview: Preview,
  contract: PreviewContract,
): Promise<PhaseChange> {
  const health = await waitForHealthy(deps, {
    imp: preview.imp,
    contract,
    windowMs: deps.settings.healthTimeoutMs,
  });

  return health.healthy
    ? { phase: 'ready', builtSHA: preview.headSHA }
    : {
        phase: 'failed',
        detail: formatUnreachablePort(contract, health),
      };
}

function formatUnreachablePort(contract: PreviewContract, health: HealthResult): string {
  return [
    `port ${contract.port} did not answer ${health.url} through impd's proxy before the boot timed out.`,
    `impd's proxy last answered: ${health.lastAnswer ?? 'nothing'}`,

    // impd's proxy reaches the app on the imp's own address, never on the guest's loopback
    `The app must listen on 0.0.0.0:${contract.port} in the imp, not on 127.0.0.1 alone.`,
  ].join('\n');
}

function pickSettledPhase(deps: PreviewDeps, preview: Preview, result: PhaseChange): PhaseChange {
  const headSHA = deps.store.findPreview(preview)?.headSHA;

  // an older head's failure says nothing about the head a push moved to meanwhile, so that preview
  // waits for its next open instead of showing the older failure
  return result.phase === 'failed' && headSHA !== preview.headSHA ? { phase: 'waiting' } : result;
}
