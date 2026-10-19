import { applySlotEvictions } from './apply-slot-evictions.ts';
import type { Preview, PreviewKey } from './create-preview-store.ts';
import { parsePreviewContract } from './parse-preview-contract.ts';
import type { PreviewPage } from './render-preview-page.ts';
import { renderPreviewPage } from './render-preview-page.ts';
import { runPreviewBoot } from './run-preview-boot.ts';
import type { PreviewDeps } from './types.ts';
import { waitForHealthy } from './wait-for-healthy.ts';

export function makeLinkHandler(deps: PreviewDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    const url = new URL(request.url);

    const key = parseLinkPath(url.pathname);

    if (request.method !== 'GET' || key === null) {
      return new Response('not found\n', { status: 404 });
    }

    const preview = deps.store.findPreview(key);
    const page = pickPreviewPage(preview, url);

    if (preview === null || page !== null) {
      return buildPageResponse(page ?? buildNoPreviewPage(key));
    }

    const response = await openPreview(deps, preview);

    return response;
  };
}

function parseLinkPath(path: string): PreviewKey | null {
  const match = /^\/(?<repo>[\w.-]+\/[\w.-]+)\/(?<number>\d+)$/u.exec(path);
  const repo = match?.groups?.['repo'];

  return repo === undefined ? null : { repo, number: Number(match?.groups?.['number']) };
}

interface StatusPage extends PreviewPage {
  readonly status: number;
}

function pickPreviewPage(preview: Preview | null, url: URL): StatusPage | null {
  if (preview?.phase === 'ended') {
    return {
      status: 410,
      title: 'Preview ended',
      message: `${formatPreview(preview)} closed, so its preview is gone.`,
    };
  }

  if (preview?.phase === 'booting') {
    return buildBootingPage(preview);
  }

  if (preview?.phase === 'failed' && url.searchParams.get('retry') !== '1') {
    return {
      status: 502,
      title: 'Preview failed',
      message: preview.detail ?? 'The boot failed.',
      action: { label: 'Retry the boot', href: `${url.pathname}?retry=1` },
    };
  }

  return null;
}

function buildNoPreviewPage(key: PreviewKey): StatusPage {
  return {
    status: 404,
    title: 'No preview',
    message: `${formatPreview(key)} has no preview: its repository has not opted in, or the service has seen no event for it.`,
  };
}

async function openPreview(deps: PreviewDeps, preview: Preview): Promise<Response> {
  const isCurrent = preview.phase === 'ready' && preview.builtSHA === preview.headSHA;

  // a boot holds the slot lock until it settles, which can take minutes, so a page waits instead
  if (isCurrent && deps.pendingBoots.size > 0) {
    return buildPageResponse(buildWaitingPage(preview));
  }

  const started = isCurrent ? await deps.withSlotLock(() => startReadyImp(deps, preview)) : false;

  if (started) {
    return Response.redirect(`https://${preview.imp}.${deps.settings.impDomain}/`, 302);
  }

  startPreviewBoot(deps, preview);

  return buildPageResponse(buildBootingPage(preview));
}

function startPreviewBoot(deps: PreviewDeps, preview: Preview): void {
  // a second open while the first one's boot starts finds the phase moved, and boots nothing
  if (!deps.store.updatePhase(preview, [preview.phase], { phase: 'booting' })) {
    return;
  }

  // the boot runs on after the response
  const boot = runPreviewBoot(deps, { ...preview, phase: 'booting' });

  deps.pendingBoots.add(boot);
  void removeSettledBoot(deps.pendingBoots, boot);
}

async function startReadyImp(deps: PreviewDeps, preview: Preview): Promise<boolean> {
  const imp = await deps.impd.findImp(preview.imp);

  if (imp === null) {
    return false;
  }

  await applySlotEvictions(deps, preview.imp);

  if (imp.state === 'running') {
    return true;
  }

  await deps.impd.wakeImp(preview.imp);

  return checkWokenStack(deps, preview);
}

// A wake that restores the imp's memory brings its containers back as they were. A cold boot
// starts dockerd alone, so a service without a restart policy stays down, and a rebuild seeds a
// fresh stack instead of starting the seed step over old data.
const wakeGraceMs = 30_000;

async function checkWokenStack(deps: PreviewDeps, preview: Preview): Promise<boolean> {
  const compose = await deps.github.readComposeFile(preview.repo, preview.headSHA);

  if (compose === null) {
    return false;
  }

  const health = await waitForHealthy(deps, {
    imp: preview.imp,
    contract: parsePreviewContract(compose),
    windowMs: wakeGraceMs,
  });

  return health.healthy;
}

async function removeSettledBoot(pending: Set<Promise<void>>, boot: Promise<void>): Promise<void> {
  // a boot never rejects: it records its own failure
  await boot;

  pending.delete(boot);
}

function buildBootingPage(preview: Preview): StatusPage {
  return {
    status: 202,
    title: 'Preview booting',
    message: `Booting ${formatPreview(preview)} at ${preview.headSHA.slice(0, 7)}. This page reloads until the preview answers.`,
    refresh: { seconds: 5, url: formatLinkPath(preview) },
  };
}

function buildWaitingPage(preview: Preview): StatusPage {
  return {
    status: 202,
    title: 'Preview waiting for a slot',
    message: `Another preview is booting. ${formatPreview(preview)} wakes once it settles; this page reloads until then.`,
    refresh: { seconds: 5, url: formatLinkPath(preview) },
  };
}

function formatPreview(preview: PreviewKey): string {
  return `${preview.repo}#${preview.number}`;
}

function formatLinkPath(preview: PreviewKey): string {
  return `/${preview.repo}/${preview.number}`;
}

function buildPageResponse(page: StatusPage): Response {
  return new Response(renderPreviewPage(page), {
    status: page.status,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
  });
}
