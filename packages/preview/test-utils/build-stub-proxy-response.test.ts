import { expect, test } from 'bun:test';
import type { StubApp } from './build-stub-proxy-response.ts';
import { buildStubProxyResponse } from './build-stub-proxy-response.ts';

function setupTest() {
  const proxied: string[] = [];

  const proxy = {
    impDomain: 'imps.example.test',
    imps: new Map([
      ['pv-0a1b2c3d-17', { name: 'pv-0a1b2c3d-17', state: 'sleeping', httpPort: 3000 }],
    ]),
    apps: new Map<string, StubApp>(),
    proxied,
  };

  return { proxy };
}

test("it forwards to an app on the imp's own address and HTTP port, waking the imp", async () => {
  const ctx = setupTest();

  ctx.proxy.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 3000 });

  const response = buildStubProxyResponse(
    ctx.proxy,
    new Request('https://pv-0a1b2c3d-17.imps.example.test/healthz'),
  );

  expect({ status: response.status, body: await response.text() }).toStrictEqual({
    status: 200,
    body: 'ok\n',
  });

  expect(ctx.proxy.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
  expect(ctx.proxy.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-17.imps.example.test/healthz']);
});

test.each([
  { case: "on the guest's loopback", app: { address: '127.0.0.1', port: 3000 } },
  { case: 'on another port', app: { address: '0.0.0.0', port: 4000 } },
  { case: 'nowhere', app: undefined },
] as const)('it answers 502 for an app $case', async (row) => {
  const ctx = setupTest();

  if (row.app !== undefined) {
    ctx.proxy.apps.set('pv-0a1b2c3d-17', row.app);
  }

  const response = buildStubProxyResponse(
    ctx.proxy,
    new Request('https://pv-0a1b2c3d-17.imps.example.test/healthz'),
  );

  expect({
    status: response.status,
    contentType: response.headers.get('content-type'),
    body: await response.text(),
  }).toStrictEqual({
    status: 502,
    contentType: 'text/html; charset=utf-8',
    body: [
      '<!doctype html>',
      '<title>Nothing answers in the imp</title>',
      '<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem">',
      '<h1>502 Nothing answers in the imp</h1>',
      '<p>pv-0a1b2c3d-17 is awake, but nothing answered on port 3000 (Unable to connect. Is the computer able to access the url?).</p>',
      '</body>',
    ].join('\n'),
  });
});

test('it answers 404 for an imp it does not hold', async () => {
  const ctx = setupTest();

  const response = buildStubProxyResponse(
    ctx.proxy,
    new Request('https://pv-0a1b2c3d-18.imps.example.test/'),
  );

  expect({ status: response.status, body: await response.text() }).toStrictEqual({
    status: 404,
    body: [
      '<!doctype html>',
      '<title>No such imp</title>',
      '<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem">',
      '<h1>404 No such imp</h1>',
      '<p>There is no imp named pv-0a1b2c3d-18.</p>',
      '</body>',
    ].join('\n'),
  });

  expect(ctx.proxy.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-18.imps.example.test/']);
});
