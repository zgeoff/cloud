// an app listening in the guest: impd's proxy reaches it only on the imp's own address, never on
// the guest's loopback
export interface StubApp {
  readonly address: '0.0.0.0' | '127.0.0.1';
  readonly port: number;
}

interface StubProxyImp {
  readonly name: string;
  state: string;
  readonly httpPort: number;
}

interface StubProxy {
  readonly impDomain: string;
  readonly imps: Map<string, StubProxyImp>;
  readonly apps: Map<string, StubApp>;
  readonly proxied: string[];
}

// impd's wake proxy at https://<name>.<domain> (zgeoff/imp v2.0.3 packages/daemon/src/proxy/): it
// wakes a sleeping imp and forwards to its HTTP port, and answers a request it cannot forward with
// its HTML error page.
export function buildStubProxyResponse(proxy: StubProxy, request: Request): Response {
  const url = new URL(request.url);

  const name = url.hostname.slice(0, -(proxy.impDomain.length + 1));

  proxy.proxied.push(`${request.method} ${url.href}`);

  const imp = proxy.imps.get(name);

  if (imp === undefined) {
    return buildImpdErrorPage(404, `There is no imp named ${name}.`);
  }

  imp.state = 'running';

  return buildForwardedResponse(proxy, imp);
}

// the refused connection carries Bun's own message
const refusedReason = 'Unable to connect. Is the computer able to access the url?';

function buildForwardedResponse(proxy: StubProxy, imp: StubProxyImp): Response {
  const app = proxy.apps.get(imp.name);

  if (app?.address !== '0.0.0.0' || app.port !== imp.httpPort) {
    return buildImpdErrorPage(
      502,
      `${imp.name} is awake, but nothing answered on port ${String(imp.httpPort)} (${refusedReason}).`,
    );
  }

  return new Response('ok\n', { status: 200 });
}

const statusTitles: Readonly<Record<number, string>> = {
  404: 'No such imp',
  502: 'Nothing answers in the imp',
};

// impd's buildErrorPage, byte for byte
function buildImpdErrorPage(status: number, detail: string): Response {
  const title = statusTitles[status] ?? 'Proxy error';

  const html = [
    '<!doctype html>',
    `<title>${encodeHTML(title)}</title>`,
    '<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem">',
    `<h1>${String(status)} ${encodeHTML(title)}</h1>`,
    `<p>${encodeHTML(detail)}</p>`,
    '</body>',
  ].join('\n');

  return new Response(html, {
    status,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function encodeHTML(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}
