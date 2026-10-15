import { buildImpName } from './build-imp-name.ts';
import type { PullRequestEvent } from './parse-pull-request-event.ts';
import { parsePullRequestEvent } from './parse-pull-request-event.ts';
import { renderPreviewComment } from './render-preview-comment.ts';
import type { PreviewDeps } from './types.ts';
import { verifyWebhookSignature } from './verify-webhook-signature.ts';

// The public endpoint, POST /webhook, for GitHub's pull_request deliveries. The signature check
// runs before anything parses the body, so an unsigned or wrongly signed call gets a 401 and
// reaches no other code.
export function makeWebhookHandler(deps: PreviewDeps): (request: Request) => Promise<Response> {
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
      await (event.action === 'close'
        ? removePreview(deps, event)
        : updatePreviewHead(deps, event));
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
// open brings an ended preview back, so a push delivered after the close never revives it; the
// check follows the last await, so a close that lands during the compose read counts.
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

// closed, merged or not: the imp goes, and the link reports the preview ended
async function removePreview(deps: PreviewDeps, event: PullRequestEvent): Promise<void> {
  const ended = deps.store.updatePhase(event, ['waiting', 'booting', 'ready', 'failed'], {
    phase: 'ended',
  });

  // the imp's name derives from the pull request, so its imp goes even without a record of it
  const imp = buildImpName(event.repo, event.number);

  const existing = await deps.impd.findImp(imp);

  if (existing !== null) {
    await deps.impd.removeImp(imp);
  }

  if (!ended) {
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
