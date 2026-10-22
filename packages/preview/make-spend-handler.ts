import type { PreviewStore } from './create-preview-store.ts';
import type { SpendProxies } from './create-spend-proxies.ts';

export interface SpendHandlerDeps {
  readonly store: PreviewStore;
  readonly proxies: SpendProxies;
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

    const origin = await deps.proxies.readOrigin(imp).catch((error: unknown) => {
      deps.log(`${imp}: ${error instanceof Error ? error.message : String(error)}`);

      return null;
    });

    // the proxy is the spend cap, so a preview whose proxy cannot start makes no model call
    if (origin === null) {
      return renderAPIError(
        503,
        'api_error',
        'the preview service could not start the counting proxy',
      );
    }

    const headers = new Headers(request.headers);

    for (const name of DROPPED_HEADERS) {
      headers.delete(name);
    }

    const body = request.body === null ? null : await request.arrayBuffer();

    const answer = await fetch(`${origin}${url.pathname}${url.search}`, {
      method: request.method,
      headers,
      body,
      redirect: 'manual',
    }).catch(() => null);

    if (answer === null) {
      return renderAPIError(502, 'api_error', 'the counting proxy did not answer');
    }

    const answerHeaders = new Headers(answer.headers);

    for (const name of [...DROPPED_HEADERS, 'content-encoding']) {
      answerHeaders.delete(name);
    }

    return new Response(answer.body, {
      status: answer.status,
      statusText: answer.statusText,
      headers: answerHeaders,
    });
  };
}

function renderAPIError(status: number, type: string, message: string): Response {
  return Response.json({ type: 'error', error: { type, message } }, { status });
}
