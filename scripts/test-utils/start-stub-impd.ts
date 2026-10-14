// the recorded requests are a mutable list by design
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { onTestFinished } from 'bun:test';

// Stands in for impd's tokens.whoami and /health on an ephemeral loopback port, for real curl to
// ask; the test stops it when it ends. Any other request fails closed with a 500 that names the
// stand-in, and every request is recorded.
export interface StubImpdRequest {
  readonly method: string;

  // the path, or the whole URL a proxy request names
  readonly target: string;
  readonly authorization: string | null;
  readonly body: string;
}

export interface StubImpd {
  readonly port: number;
  readonly requests: readonly StubImpdRequest[];
}

// IdentitySchema in imp 1.0.0's packages/api/src/token-schema.ts, in the {"json": …} envelope of
// @orpc/server 1.14.15; whether oRPC adds "meta" beside "json" needs an impd sample
const identity =
  '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}';

export interface StubImpdHealth {
  readonly status: number;
  readonly body: string;
}

// impd-local-health.sh counts impd up on a 200 whose body holds "ready":true; the rest of the
// real body needs an impd sample
const readyHealth: StubImpdHealth = { status: 200, body: '{"ready":true}' };

export function startStubImpd(goodToken: string, health: StubImpdHealth = readyHealth): StubImpd {
  const requests: StubImpdRequest[] = [];

  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch: async (request): Promise<Response> => {
      const url = new URL(request.url);

      const authorization = request.headers.get('authorization');

      // a proxy request names a whole URL, which Bun hands on as the request's URL
      const target: string = url.host === `127.0.0.1:${server.port}` ? url.pathname : request.url;

      requests.push({ method: request.method, target, authorization, body: await request.text() });

      return buildImpdResponse(
        { method: request.method, target, authorization },
        goodToken,
        health,
      );
    },
  });

  onTestFinished(() => server.stop(true));

  return { port: server.port ?? 0, requests };
}

interface ImpdRoute {
  readonly method: string;
  readonly target: string;
  readonly authorization: string | null;
}

function buildImpdResponse(route: ImpdRoute, goodToken: string, health: StubImpdHealth) {
  if (route.method === 'GET' && route.target === '/health') {
    return new Response(health.body, {
      status: health.status,
      headers: { 'content-type': 'application/json' },
    });
  }

  if (route.method !== 'POST' || route.target !== '/rpc/tokens/whoami') {
    return new Response('not impd: start-stub-impd.ts\n', { status: 500 });
  }

  // the 401 body of imp 1.0.0's packages/daemon/src/build-app.ts line 296
  if (route.authorization !== `Bearer ${goodToken}`) {
    return Response.json({ error: 'unauthorized' }, { status: 401 });
  }

  return new Response(identity, { headers: { 'content-type': 'application/json' } });
}
