// each test states its whole host, registry and route inline and asserts the whole output, so its
// body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { checkATCGatewayReadiness } from './check-atc-gateway-readiness.ts';
import { server } from './mocks/node.ts';
import { buildStubGetent } from './test-utils/build-stub-getent.ts';
import { buildStubReadinessHost } from './test-utils/build-stub-readiness-host.ts';
import type { StubAnswer, StubCall } from './test-utils/build-stub-runner.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

// recorders for the output; the host, registry and route are each test's own
function setupTest() {
  const out: string[] = [];
  const err: string[] = [];

  return {
    out,
    err,
    printOut: (text: string) => {
      out.push(text);
    },
    printErr: (text: string) => {
      err.push(text);
    },
  };
}

// gh prints the token it holds, as `gh auth token` does once signed in or with GH_TOKEN set
function buildGHAuthTokenAnswer(call: StubCall): StubAnswer | undefined {
  return call.argv.join(' ') === 'gh auth token --hostname github.com'
    ? { stdout: 'gh-token-1\n' }
    : undefined;
}

test('it reports every check ok and exits 0 once the gateway is deployed', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: ['atc'],
      storageClasses: ['local-path-retain'],
      deployments: { 'ingress/cloudflared': 1, 'atc/atc-gateway': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '200',
    }),
    buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }),
  );

  const bearers: (string | null)[] = [];

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.json({ token: 'ghcr-t1' })),

    // MSW's resolver info carries a Request, which has no readonly form
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types
    http.get('https://ghcr.io/v2/zgeoff/atc-gateway/tags/list', (info) => {
      bearers.push(info.request.headers.get('authorization'));

      return HttpResponse.json({ name: 'zgeoff/atc-gateway', tags: ['1.0.0'] });
    }),
    http.get('https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp', () =>
      HttpResponse.json({ resource: 'https://atc.geoff.cloud/mcp' }),
    ),
  );

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.err).toStrictEqual([]);
  expect(bearers).toStrictEqual(['Bearer ghcr-t1']);

  expect(ctx.out.join('')).toBe(
    'ok       k3s node on geoffcloud is Ready\n' +
      'ok       host has 2048 MiB available (gateway needs 256 MiB)\n' +
      'ok       cloudflared has ready replicas\n' +
      'ok       exists: namespace atc\n' +
      'ok       exists: storageclass local-path-retain\n' +
      'ok       exists: -n atc deploy atc-gateway\n' +
      'ok       image ghcr.io/zgeoff/atc-gateway exists\n' +
      'ok       atc.geoff.cloud protected-resource metadata: 200\n' +
      "ok       impd is ready on geoffcloud's loopback\n" +
      'ok       atc-daemon is active on geoffcloud\n' +
      'ok       gateway in-cluster metadata: 200\n',
  );

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' 'get' 'nodes' '--no-headers'",
    ],
    ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'root@geoffcloud', "'free' '-m'"],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' '-n' 'ingress' 'get' 'deploy' 'cloudflared' '-o' 'jsonpath={.status.readyReplicas}'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' 'get' 'namespace' 'atc'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' 'get' 'storageclass' 'local-path-retain'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' 'get' '-n' 'atc' 'deploy' 'atc-gateway'",
    ],
    ['gh', 'auth', 'token', '--hostname', 'github.com'],
    ['getent', 'hosts', 'atc.geoff.cloud'],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'bash' '-s' '--' '7070'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'systemctl' 'is-active' '--quiet' 'atc-daemon'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' '-n' 'atc' 'get' 'deploy' 'atc-gateway'",
    ],
    [
      'ssh',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=15',
      'root@geoffcloud',
      "'k3s' 'kubectl' '-n' 'atc' 'run' 'readiness-probe' '--rm' '-i' '--restart=Never' '--quiet' '--image=curlimages/curl:8.16.0' '--' 'curl' '-s' '-o' '/dev/null' '-w' '%{http_code}' '-H' 'Host: atc.geoff.cloud' 'http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp'",
    ],
  ]);
});

test('it reports what the deploy creates as missing, and exits 0, before the deploy', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: false,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.json({ token: 'ghcr-t1' })),
    http.get(
      'https://ghcr.io/v2/zgeoff/atc-gateway/tags/list',
      () => new HttpResponse(null, { status: 404 }),
    ),
  );

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'ok       k3s node on geoffcloud is Ready\n' +
      'ok       host has 2048 MiB available (gateway needs 256 MiB)\n' +
      'ok       cloudflared has ready replicas\n' +
      'missing  namespace atc\n' +
      'missing  storageclass local-path-retain\n' +
      'missing  -n atc deploy atc-gateway\n' +
      'missing  image ghcr.io/zgeoff/atc-gateway\n' +
      'missing  DNS record atc.geoff.cloud\n' +
      "ok       impd is ready on geoffcloud's loopback\n" +
      'missing  atc-daemon service on geoffcloud\n',
  );

  expect(stub.calls.filter((call) => (call.argv.at(-1) ?? '').includes("'run'"))).toStrictEqual([]);
});

test('it fails the four host checks and exits 4 when the host does not answer', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      isUnreachable: true,
      nodeLine: '',
      availableMiB: 0,
      namespaces: [],
      storageClasses: [],
      deployments: {},
      isDaemonActive: true,
      impdHealth: '',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(4);
  expect(ctx.err).toStrictEqual([]);

  expect(ctx.out.join('')).toBe(
    'FAIL     k3s node on geoffcloud is not Ready, or geoffcloud is unreachable over the tailnet\n' +
      'FAIL     host has ? MiB available\n' +
      'FAIL     cloudflared has no ready replica\n' +
      'missing  namespace atc\n' +
      'missing  storageclass local-path-retain\n' +
      'missing  -n atc deploy atc-gateway\n' +
      'missing  image ghcr.io/zgeoff/atc-gateway\n' +
      'missing  DNS record atc.geoff.cloud\n' +
      "FAIL     impd is not ready on geoffcloud's loopback: 000\n" +
      'missing  atc-daemon service on geoffcloud\n',
  );
});

test('it fails the node check when the node is not Ready, and the memory check below 1024 MiB', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   NotReady   control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 1023,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 0 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(3);

  expect(ctx.out.slice(0, 3).join('')).toBe(
    'FAIL     k3s node on geoffcloud is not Ready, or geoffcloud is unreachable over the tailnet\n' +
      'FAIL     host has 1023 MiB available\n' +
      'FAIL     cloudflared has no ready replica\n',
  );
});

test('it passes the memory check at exactly 1024 MiB available', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 1024,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 2 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.out[0]).toBe('ok       k3s node on geoffcloud is Ready\n');
  expect(ctx.out[1]).toBe('ok       host has 1024 MiB available (gateway needs 256 MiB)\n');
});

test('it fails the impd check with impd’s status when impd is not ready', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: true,
      impdHealth: '503 0',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toContain("FAIL     impd is not ready on geoffcloud's loopback: 503\n");
});

test('it fails the public route when its metadata answers another status', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }),
  );

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.error()),
    http.get(
      'https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp',
      () => new HttpResponse('bad gateway', { status: 502 }),
    ),
  );

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toContain('FAIL     atc.geoff.cloud protected-resource metadata: 502\n');
});

test('it fails the public route with 000 when its metadata gets no answer', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }),
  );

  server.use(
    http.get('https://ghcr.io/token', () => HttpResponse.error()),
    http.get('https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp', () =>
      HttpResponse.error(),
    ),
  );

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toContain('FAIL     atc.geoff.cloud protected-resource metadata: 000\n');
});

test('it fails the in-cluster check when the gateway answers another status', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud',
      nodeLine: 'geoffcloud   Ready    control-plane,master   40d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: ['atc'],
      storageClasses: ['local-path-retain'],
      deployments: { 'ingress/cloudflared': 1, 'atc/atc-gateway': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '403',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: [],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out.at(-1)).toBe('FAIL     gateway in-cluster metadata: 403\n');
});

test('it checks the named host', async () => {
  const ctx = setupTest();

  const stub = buildStubRunner(
    buildGHAuthTokenAnswer,
    buildStubReadinessHost({
      destination: 'root@geoffcloud-2',
      nodeLine: 'geoffcloud-2   Ready    control-plane,master   1d   v1.33.4+k3s1',
      availableMiB: 2048,
      namespaces: [],
      storageClasses: [],
      deployments: { 'ingress/cloudflared': 1 },
      isDaemonActive: true,
      impdHealth: '200 1',
      probeCode: '',
    }),
    buildStubGetent({}),
  );

  server.use(http.get('https://ghcr.io/token', () => HttpResponse.error()));

  const exitCode = await checkATCGatewayReadiness({
    args: ['geoffcloud-2'],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.out[0]).toBe('ok       k3s node on geoffcloud-2 is Ready\n');
  expect(ctx.out.at(-1)).toBe('ok       atc-daemon is active on geoffcloud-2\n');
});

test('it prints its usage and exits 2 for more than one host', async () => {
  const ctx = setupTest();
  const stub = buildStubRunner();

  const exitCode = await checkATCGatewayReadiness({
    args: ['geoffcloud', 'more'],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.err).toStrictEqual(['usage: check-atc-gateway-readiness.ts [<host>]\n']);
  expect(stub.calls).toStrictEqual([]);
});
