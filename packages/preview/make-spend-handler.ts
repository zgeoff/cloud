import { match } from 'ts-pattern';
import { buildForwardedHeaders } from './build-forwarded-headers.ts';
import type { PreviewStore } from './create-preview-store.ts';
import type { ProxyHold, SpendProxies } from './create-spend-proxies.ts';
import { modelRoute } from './model-route.ts';
import { pickProxyOutcome } from './pick-proxy-outcome.ts';
import { pickSpendAdmission } from './pick-spend-admission.ts';
import { renderSpendRefusal } from './render-spend-refusal.ts';

export interface SpendHandlerDeps {
  readonly store: PreviewStore;
  readonly proxies: SpendProxies;
  readonly sendRequest: (url: string, init: RequestInit) => Promise<Response>;
  readonly log: (line: string) => void;
}

// The broker sends a preview's model calls here on the preview's model route, and the imp's grant
// filter lets it send no other, so the route picks the proxy.
export function makeSpendHandler(deps: SpendHandlerDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    const url = new URL(request.url);

    const body = request.body === null ? null : await request.arrayBuffer();

    // A close marks the preview ended before it removes the proxy, and nothing awaits between
    // this check and the hold, so a closed preview never gets a proxy that the close missed.
    const route = modelRoute.parsePath(url.pathname);
    const preview = route === null ? null : deps.store.findPreviewByImp(route.imp);
    const admission = pickSpendAdmission(url.pathname, route, preview?.phase ?? null);

    if (!admission.admitted) {
      return renderSpendRefusal(admission.refusal);
    }

    const hold = await deps.proxies.holdProxy(admission.imp).catch((error: unknown) => {
      deps.log(`${admission.imp}: ${error instanceof Error ? error.message : String(error)}`);

      return null;
    });

    const answer = await sendToProxy(deps, hold, request, body);

    const outcome = pickProxyOutcome(hold, answer);

    outcome.holdToRelease?.release();

    return match(outcome)
      .with({ kind: 'refuse' }, (refused) => renderSpendRefusal(refused.refusal))
      .with({ kind: 'forward' }, (forwarded) => {
        const forwardedBody =
          forwarded.watchedBody === null
            ? null
            : buildReleasingBody(forwarded.watchedBody, forwarded.hold);

        return new Response(forwardedBody, {
          status: forwarded.answer.status,
          statusText: forwarded.answer.statusText,
          headers: buildForwardedHeaders(forwarded.answer.headers, 'answer'),
        });
      })
      .exhaustive();
  };
}

async function sendToProxy(
  deps: SpendHandlerDeps,
  hold: ProxyHold | null,
  request: Request,
  body: ArrayBuffer | null,
): Promise<Response | null> {
  if (hold === null) {
    return null;
  }

  const url = new URL(request.url);

  try {
    return await deps.sendRequest(`${hold.origin}${url.pathname}${url.search}`, {
      method: request.method,
      headers: buildForwardedHeaders(request.headers, 'call'),
      body,
      redirect: 'manual',
    });
  } catch {
    return null;
  }
}

function buildReleasingBody(
  body: ReadableStream<Uint8Array>,
  hold: ProxyHold,
): ReadableStream<Uint8Array> {
  const reader = body.getReader();

  return new ReadableStream({
    pull: async (controller) => {
      try {
        const next = await reader.read();

        if (next.done) {
          hold.release();
          controller.close();

          return;
        }

        controller.enqueue(next.value);
      } catch (error) {
        hold.release();
        controller.error(error);
      }
    },
    cancel: async (reason) => {
      hold.release();

      await reader.cancel(reason);
    },
  });
}
