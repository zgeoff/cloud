import type { Preview, PreviewKey } from './create-preview-store.ts';
import { planSlotEvictions } from './plan-slot-evictions.ts';
import type { PreviewPage } from './render-preview-page.ts';
import { renderPreviewPage } from './render-preview-page.ts';
import { runPreviewBoot } from './run-preview-boot.ts';
import type { PreviewDeps } from './types.ts';

// The tailnet link, GET /<owner>/<name>/<number>. A ready preview of the head commit redirects to
// its imp, which impd's wake proxy serves; any other preview gets a page that says where it stands.
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

    return await openPreview(deps, preview);
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

// The page for a preview that the link cannot open now, or null for one it can
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

// Frees a slot first: before a preview wakes or boots, the least recently used previews sleep
// until it fits. A ready preview of the head commit wakes and redirects; any other boots.
async function openPreview(deps: PreviewDeps, preview: Preview): Promise<Response> {
  await applySlotEvictions(deps, preview.imp);

  const imp = await deps.impd.findImp(preview.imp);

  if (preview.phase === 'ready' && preview.builtSHA === preview.headSHA && imp !== null) {
    if (imp.state !== 'running') {
      await deps.impd.wakeImp(preview.imp);
    }

    return Response.redirect(`https://${preview.imp}.${deps.settings.impDomain}/`, 302);
  }

  startPreviewBoot(deps, preview);

  return buildPageResponse(buildBootingPage(preview));
}

// A second open while the first one's boot starts finds the phase moved, and boots nothing. The
// boot runs on after the response.
function startPreviewBoot(deps: PreviewDeps, preview: Preview): void {
  if (!deps.store.updatePhase(preview, [preview.phase], { phase: 'booting' })) {
    return;
  }

  const boot = runPreviewBoot(deps, { ...preview, phase: 'booting' });

  deps.pendingBoots.add(boot);
  void removeSettledBoot(deps.pendingBoots, boot);
}

async function applySlotEvictions(deps: PreviewDeps, opening: string): Promise<void> {
  const imps = await deps.impd.readImps();

  const evictions = planSlotEvictions(imps, deps.settings.slots, opening);

  // a preview that will not sleep, such as one under a lease, keeps running beside the opening one
  for (const name of evictions) {
    try {
      // oxlint-disable-next-line no-await-in-loop -- one sleep at a time keeps impd's work bounded
      await deps.impd.sleepImp(name);

      deps.log(`${name}: asleep to free a slot for ${opening}`);
    } catch (error) {
      deps.log(`${name}: could not sleep it to free a slot: ${String(error)}`);
    }
  }
}

// a boot never rejects: it records its own failure
async function removeSettledBoot(pending: Set<Promise<void>>, boot: Promise<void>): Promise<void> {
  await boot;

  pending.delete(boot);
}

function buildBootingPage(preview: Preview): StatusPage {
  return {
    status: 202,
    title: 'Preview booting',
    message: `Booting ${formatPreview(preview)} at ${preview.headSHA.slice(0, 7)}. This page reloads until the preview answers.`,
    refreshSeconds: 5,
  };
}

function formatPreview(preview: PreviewKey): string {
  return `${preview.repo}#${preview.number}`;
}

function buildPageResponse(page: StatusPage): Response {
  return new Response(renderPreviewPage(page), {
    status: page.status,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
  });
}
