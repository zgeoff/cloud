import { buildContractImpName } from './build-contract-imp-name.ts';
import { buildImpName } from './build-imp-name.ts';
import { hasSDKPinChange } from './has-sdk-pin-change.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import type { PullRequestEvent } from './parse-pull-request-event.ts';
import { parsePullRequestEvent } from './parse-pull-request-event.ts';
import { renderPreviewComment } from './render-preview-comment.ts';
import { startContractRun } from './start-contract-run.ts';
import type { PreviewDeps } from './types.ts';
import { verifyWebhookSignature } from './verify-webhook-signature.ts';

export function makeWebhookHandler(deps: PreviewDeps): (request: Request) => Promise<Response> {
  const withDeliveryLock = makeSlotLock();

  return async (request) => {
    if (new URL(request.url).pathname !== '/webhook' || request.method !== 'POST') {
      return new Response('not found\n', { status: 404 });
    }

    const body = await request.arrayBuffer();

    const signature = request.headers.get('x-hub-signature-256');

    // before anything parses the body, so a bad signature reaches no other code
    if (!(await verifyWebhookSignature(deps.webhookSecret, body, signature))) {
      return new Response('signature mismatch\n', { status: 401 });
    }

    const event =
      request.headers.get('x-github-event') === 'pull_request'
        ? parsePullRequestEvent(JSON.parse(new TextDecoder().decode(body)))
        : null;

    if (event !== null) {
      // one delivery at a time, in arrival order, so an older one never lands after a newer one
      await withDeliveryLock(() => applyPullRequestEvent(deps, event));
    }

    return new Response(null, { status: 204 });
  };
}

async function applyPullRequestEvent(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  if (shouldPreview(deps, event)) {
    await (event.action === 'close' ? removePreview(deps, event) : updatePreviewHead(deps, event));
  }

  if (shouldCheckContract(deps, event)) {
    await claimContractRun(deps, event);
  }
}

function shouldPreview(deps: PreviewDeps, event: PullRequestEvent): boolean {
  const owner = event.repo.split('/')[0] ?? '';
  const listed = deps.settings.repos.has(event.repo) || deps.settings.repos.has(`${owner}/*`);

  // a fork's code would run in an imp that holds the broker's GitHub credential
  return listed && !event.fromFork;
}

// A close the service saw before any head leaves this mark on its ended record, so a late push
// finds the preview ended and a redelivered close posts no comment
const unseenCloseDetail = 'the pull request closed before any preview';

async function removePreview(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const before = deps.store.findPreview(event);

  updatePreviewEnded(deps, event, before === null);

  // the imp's name derives from the pull request, so its imp goes even without a record of it
  const imp = buildImpName(event.repo, event.number);

  const existing = await deps.impd.readImp(imp);

  await (existing === null ? Promise.resolve() : deps.impd.removeImp(imp));

  // a reopened pull request starts its spend from zero
  await deps.spendProxies?.removeProxy(imp);

  if (before === null || before.detail === unseenCloseDetail) {
    return;
  }

  const link = `${deps.settings.baseURL}/${event.repo}/${event.number}`;

  await deps.github.updatePreviewComment({
    repo: event.repo,
    number: event.number,
    body: renderPreviewComment(link, null),
  });

  deps.log(`${event.repo}#${event.number}: preview ended`);
}

function updatePreviewEnded(deps: PreviewDeps, event: PullRequestEvent, unseen: boolean): void {
  const imp = buildImpName(event.repo, event.number);

  if (unseen) {
    deps.store.upsertHead({ repo: event.repo, number: event.number, imp, headSHA: event.headSHA });
  }

  deps.store.updatePhase(event, ['waiting', 'booting', 'ready', 'failed'], {
    phase: 'ended',
    ...(unseen ? { detail: unseenCloseDetail } : {}),
  });
}

async function updatePreviewHead(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const compose = await deps.github.readComposeFile(event.repo, event.headSHA);

  // only an open brings an ended preview back, so a push delivered after the close never
  // revives it
  if (compose === null || isEndedPush(deps, event)) {
    return;
  }

  const imp = buildImpName(event.repo, event.number);

  deps.store.upsertHead({ repo: event.repo, number: event.number, imp, headSHA: event.headSHA });

  const link = `${deps.settings.baseURL}/${event.repo}/${event.number}`;

  await deps.github.updatePreviewComment({
    repo: event.repo,
    number: event.number,
    body: renderPreviewComment(link, event.headSHA),
  });

  deps.log(`${event.repo}#${event.number}: preview link for ${event.headSHA}`);
}

function isEndedPush(deps: PreviewDeps, event: PullRequestEvent): boolean {
  return event.action === 'update' && deps.store.findPreview(event)?.phase === 'ended';
}

function shouldCheckContract(deps: PreviewDeps, event: PullRequestEvent): boolean {
  const repos = deps.settings.contract?.repos;

  // the suite runs with the broker's model credential, so a fork's code never runs it
  if (repos === undefined || event.action === 'close' || event.fromFork) {
    return false;
  }

  const owner = event.repo.split('/')[0] ?? '';

  return repos.has(event.repo) || repos.has(`${owner}/*`);
}

async function claimContractRun(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const files = await deps.github.readPullRequestFiles(event.repo, event.number);

  if (!hasSDKPinChange(files)) {
    return;
  }

  const key = { repo: event.repo, headSHA: event.headSHA };

  const claimed = deps.store.claimContractRun({
    ...key,
    number: event.number,
    imp: buildContractImpName(event.repo, event.headSHA),
  });

  // a later delivery for the same commit, such as a reopen or GitHub's redelivery, finds the run
  // claimed and starts nothing
  if (claimed) {
    deps.log(`${event.repo}#${event.number}: an SDK contract run for ${event.headSHA}`);

    startContractRun(deps, key);
  }
}
