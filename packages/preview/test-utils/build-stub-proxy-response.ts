// an app listening in the guest: impd's proxy reaches it only on the imp's own address, never on
// the guest's loopback
export interface StubApp {
  readonly address: '0.0.0.0' | '127.0.0.1';
  readonly port: number;
}

interface StubProxy {
  readonly impDomain: string;
  readonly imps: Map<string, { readonly name: string; state: string; readonly httpPort: number }>;
  readonly apps: Map<string, StubApp>;
  readonly proxied: string[];
}

// impd's wake proxy at https://<name>.<domain>: it wakes a sleeping imp and forwards to its HTTP
// port, and answers 502 with the text a live preview check saw when no app listens there on the
// imp's own address. The stub's answer for an unknown imp is its own.
export function buildStubProxyResponse(proxy: StubProxy, request: Request): Response {
  const url = new URL(request.url);

  proxy.proxied.push(`${request.method} ${url.href}`);

  const imp = proxy.imps.get(url.hostname.slice(0, -(proxy.impDomain.length + 1)));

  if (imp === undefined) {
    return new Response('no such imp\n', { status: 404 });
  }

  imp.state = 'running';

  const app = proxy.apps.get(imp.name);

  if (app?.address !== '0.0.0.0' || app.port !== imp.httpPort) {
    return new Response('Nothing answers in the imp\n', { status: 502 });
  }

  return new Response('ok\n', { status: 200 });
}
