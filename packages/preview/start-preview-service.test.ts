import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { createPreviewStore } from './create-preview-store.ts';
import { stubApp } from './mocks/github-app.ts';
import { server as mockServer } from './mocks/node.ts';
import { startPreviewService } from './start-preview-service.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import { waitForCondition } from './test-utils/wait-for-condition.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-service-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // the listeners and each proxy take loopback ports, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  return { directory, stubPath: join(import.meta.dir, 'test-utils', 'run-stub-counting-proxy.ts') };
}

test('it puts every imp impd lists under the public egress policy when it starts', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const service = startPreviewService({
    settings: {
      baseURL: 'http://cloudhost.test:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'pv-base',
      impMemoryMib: 2048,
      impGitHubSecret: null,
      impModelSecret: null,
      buildTimeoutMs: 600_000,
      healthTimeoutMs: 120_000,
      healthPollMs: 1000,
      contract: null,
    },
    linkListener: { hostname: '127.0.0.1', port: 0 },
    webhookListener: { hostname: '127.0.0.1', port: 0 },
    impdURL: impd.url,
    databasePath: join(ctx.directory, 'previews.sqlite'),
    webhookSecret: 'whsec-example',
    githubApp: stubApp,
    impdToken: impd.token,
    sweepIntervalMs: 3_600_000,
    spend: null,
  });

  onTestFinished(() => service.stop());

  await waitForCondition(() => impd.egressModes.size > 0);

  expect(impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-7', 'public']]));
});

test('it keeps the model route listener closed until every imp has the public egress policy', async () => {
  const ctx = await setupTest();

  const impd = startStubImpd();

  impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'pv-base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const held = { policy: false };
  const release = Promise.withResolvers<void>();

  mockServer.use(
    http.post(`${impd.url}/rpc/imps/setPolicy`, async () => {
      held.policy = true;

      await release.promise;

      return passthrough();
    }),
  );

  // the route listener needs a known port, so the test takes a free one from the kernel first
  const probe = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data: () => {} } });
  const port = probe.port;

  probe.stop(true);

  const service = startPreviewService({
    settings: {
      baseURL: 'http://cloudhost.test:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'pv-base',
      impMemoryMib: 2048,
      impGitHubSecret: null,
      impModelSecret: 'preview-model-counted',
      buildTimeoutMs: 600_000,
      healthTimeoutMs: 120_000,
      healthPollMs: 1000,
      contract: null,
    },
    linkListener: { hostname: '127.0.0.1', port: 0 },
    webhookListener: { hostname: '127.0.0.1', port: 0 },
    impdURL: impd.url,
    databasePath: join(ctx.directory, 'previews.sqlite'),
    webhookSecret: 'whsec-example',
    githubApp: stubApp,
    impdToken: impd.token,
    sweepIntervalMs: 3_600_000,
    spend: {
      listener: { hostname: '127.0.0.1', port },
      settings: {
        proxyPath: ctx.stubPath,
        directory: join(ctx.directory, 'spend'),
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
        limitDollars: 2,
        idleMs: 1_800_000,
      },
    },
  });

  onTestFinished(() => service.stop());

  await waitForCondition(() => held.policy);

  const reached = await fetch(`http://127.0.0.1:${String(port)}/`).then(
    () => true,
    () => false,
  );

  release.resolve();

  await waitForCondition(() =>
    fetch(`http://127.0.0.1:${String(port)}/`).then(
      () => true,
      () => false,
    ),
  );

  expect(reached).toBeFalse();
  expect(impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-7', 'public']]));
});

test("it sends a preview's model call from its route listener to that preview's proxy", async () => {
  const ctx = await setupTest();

  const seed = createPreviewStore(join(ctx.directory, 'previews.sqlite'));

  seed.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  seed.close();

  // the route listener needs a known port, so the test takes a free one from the kernel first
  const probe = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data: () => {} } });
  const port = probe.port;

  probe.stop(true);

  const impd = startStubImpd();

  const service = startPreviewService({
    settings: {
      baseURL: 'http://cloudhost.test:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'pv-base',
      impMemoryMib: 2048,
      impGitHubSecret: null,
      impModelSecret: 'preview-model-counted',
      buildTimeoutMs: 600_000,
      healthTimeoutMs: 120_000,
      healthPollMs: 1000,
      contract: null,
    },
    linkListener: { hostname: '127.0.0.1', port: 0 },
    webhookListener: { hostname: '127.0.0.1', port: 0 },
    impdURL: impd.url,
    databasePath: join(ctx.directory, 'previews.sqlite'),
    webhookSecret: 'whsec-example',
    githubApp: stubApp,
    impdToken: impd.token,
    sweepIntervalMs: 3_600_000,
    spend: {
      listener: { hostname: '127.0.0.1', port },
      settings: {
        proxyPath: ctx.stubPath,
        directory: join(ctx.directory, 'spend'),
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
        limitDollars: 2,
        idleMs: 1_800_000,
      },
    },
  });

  onTestFinished(() => service.stop());

  await waitForCondition(() =>
    fetch(`http://127.0.0.1:${String(port)}/`).then(
      () => true,
      () => false,
    ),
  );

  const response = await fetch(`http://127.0.0.1:${String(port)}/pv-0a1b2c3d-7/v1/messages`, {
    method: 'POST',
    body: '{"model":"model-small"}',
  });

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    method: 'POST',
    path: '/pv-0a1b2c3d-7/v1/messages',
    body: '{"model":"model-small"}',
    routes: ['pv-0a1b2c3d-7'],
    limit: 2,
  });
});
