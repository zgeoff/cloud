import type { PreviewStore } from './create-preview-store.ts';
import type { ProxyHold, SpendProxies } from './create-spend-proxies.ts';

export interface SpendHandlerDeps {
  readonly store: PreviewStore;
  readonly proxies: SpendProxies;
  readonly sendRequest: (url: string, init: RequestInit) => Promise<Response>;
  readonly log: (line: string) => void;
}

// a hop-by-hop header, or one that describes a body this listener sends on as it arrived
const DROPPED_HEADERS = ['host', 'connection', 'keep-alive', 'transfer-encoding', 'content-length'];

// The broker sends a preview's model calls here with the preview imp's name as the first path
// segment, and the imp's grant filter lets it send no other, so the segment picks the proxy.
export function makeSpendHandler(deps: SpendHandlerDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    const url = new URL(request.url);

    const imp = url.pathname.split('/')[1] ?? '';
    const preview = imp === '' ? null : deps.store.findPreviewByImp(imp);

    if (preview === null || preview.phase === 'ended') {
      return renderAPIError(
        404,
        'not_found_error',
        `no preview holds the model route ${url.pathname}`,
      );
    }

    const headers = new Headers(request.headers);

    for (const name of DROPPED_HEADERS) {
      headers.delete(name);
    }

    const body = request.body === null ? null : await request.arrayBuffer();

    const hold = await deps.proxies.holdProxy(imp).catch((error: unknown) => {
      deps.log(`${imp}: ${error instanceof Error ? error.message : String(error)}`);

      return null;
    });

    // the proxy is the spend cap, so a preview whose proxy cannot start makes no model call
    if (hold === null) {
      return renderAPIError(
        503,
        'api_error',
        'the preview service could not start the counting proxy',
      );
    }

    const answer = await deps
      .sendRequest(`${hold.origin}${url.pathname}${url.search}`, {
        method: request.method,
        headers,
        body,
        redirect: 'manual',
      })
      .catch(() => null);

    if (answer === null) {
      hold.release();

      return renderAPIError(502, 'api_error', 'the counting proxy did not answer');
    }

    if (answer.body === null) {
      hold.release();
    }

    const answerHeaders = new Headers(answer.headers);

    for (const name of [...DROPPED_HEADERS, 'content-encoding']) {
      answerHeaders.delete(name);
    }

    // a streamed reply can outlast the idle time, so the hold lasts until its body ends
    const answerBody = answer.body === null ? null : buildReleasingBody(answer.body, hold);

    return new Response(answerBody, {
      status: answer.status,
      statusText: answer.statusText,
      headers: answerHeaders,
    });
  };
}

function renderAPIError(status: number, type: string, message: string): Response {
  return Response.json({ type: 'error', error: { type, message } }, { status });
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
