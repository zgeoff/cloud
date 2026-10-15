import { buildImpName } from './build-imp-name.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import type { PullRequestEvent } from './parse-pull-request-event.ts';
import { parsePullRequestEvent } from './parse-pull-request-event.ts';
import { renderPreviewComment } from './render-preview-comment.ts';
import type { PreviewDeps } from './types.ts';
import { verifyWebhookSignature } from './verify-webhook-signature.ts';

// The public endpoint, POST /webhook, for GitHub's pull_request deliveries. The signature check runs
// before anything parses the body, so a bad signature gets a 401 and reaches no other code. One
// delivery runs at a time, in arrival order, so an older one never lands after a newer one.
export function makeWebhookHandler(deps: PreviewDeps): (request: Request) => Promise<Response> {
  const withDeliveryLock = makeSlotLock();

  return async (request) => {
    if (new URL(request.url).pathname !== '/webhook' || request.method !== 'POST') {
      return new Response('not found\n', { status: 404 });
    }

    const body = await request.arrayBuffer();

    const signature = request.headers.get('x-hub-signature-256');

    if (!(await verifyWebhookSignature(deps.webhookSecret, body, signature))) {
      return new Response('signature mismatch\n', { status: 401 });
    }

    const event =
      request.headers.get('x-github-event') === 'pull_request'
        ? parsePullRequestEvent(JSON.parse(new TextDecoder().decode(body)))
        : null;

    if (event !== null && shouldPreview(deps, event)) {
      await withDeliveryLock(() =>
        event.action === 'close' ? removePreview(deps, event) : updatePreviewHead(deps, event),
      );
    }

    return new Response(null, { status: 204 });
  };
}

// A fork's code would run in an imp that holds the broker's GitHub credential, so a pull request
// from a fork gets no preview, and neither does one in a repository the service does not list,
// by name or by its owner's `<owner>/*`
function shouldPreview(deps: PreviewDeps, event: PullRequestEvent): boolean {
  const owner = event.repo.split('/')[0] ?? '';
  const listed = deps.settings.repos.has(event.repo) || deps.settings.repos.has(`${owner}/*`);

  return listed && !event.fromFork;
}

// opened, reopened or synchronize: a head commit with preview/compose.yaml gets the link. Only an
// open brings an ended preview back, so a push delivered after the close never revives it.
async function updatePreviewHead(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const compose = await deps.github.readComposeFile(event.repo, event.headSHA);

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

// A close the service saw before any head leaves this mark on its ended record, so a late push
// finds the preview ended and a redelivered close posts no comment
const unseenCloseDetail = 'the pull request closed before any preview';

// closed, merged or not: the imp goes, and the link reports the preview ended. A redelivered close
// retries both, so a failed removal or comment heals on GitHub's next attempt.
async function removePreview(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const before = deps.store.findPreview(event);

  updatePreviewEnded(deps, event, before === null);

  // the imp's name derives from the pull request, so its imp goes even without a record of it
  const imp = buildImpName(event.repo, event.number);

  const existing = await deps.impd.findImp(imp);

  await (existing === null ? Promise.resolve() : deps.impd.removeImp(imp));

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
