import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { createPreviewStore } from './create-preview-store.ts';
import { createSpendProxies } from './create-spend-proxies.ts';
import { makeSpendHandler } from './make-spend-handler.ts';
import { server as mockServer } from './mocks/node.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'spend-handler-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // each proxy's port comes from the kernel, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  return {
    directory,
    store,
    stubPath: join(import.meta.dir, 'test-utils', 'run-stub-counting-proxy.ts'),
    deps: { now: () => new Date('2026-10-15T09:00:00Z'), log: () => {} },
  };
}

test('it sends a preview model call to that preview proxy and answers with what the proxy answered', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  const proxies = createSpendProxies(
    {
      proxyPath: ctx.stubPath,
      directory: join(ctx.directory, 'spend'),
      upstream: 'https://models.example.test',
      model: 'model-small',
      prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      limitDollars: 2,
      idleMs: 1_800_000,
    },
    ctx.deps,
  );

  onTestFinished(() => proxies.removeAll());

  const handler = makeSpendHandler({ store: ctx.store, proxies, log: () => {} });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages?beta=true', {
      method: 'POST',
      body: '{"model":"model-small"}',
    }),
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    method: 'POST',
    path: '/pv-0a1b2c3d-7/v1/messages?beta=true',
    body: '{"model":"model-small"}',
    routes: ['pv-0a1b2c3d-7'],
    limit: 2,
  });
});

test('it answers a route that names no preview with a 404 and starts no proxy', async () => {
  const ctx = await setupTest();

  const proxies = createSpendProxies(
    {
      proxyPath: ctx.stubPath,
      directory: join(ctx.directory, 'spend'),
      upstream: 'https://models.example.test',
      model: 'model-small',
      prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      limitDollars: 2,
      idleMs: 1_800_000,
    },
    ctx.deps,
  );

  onTestFinished(() => proxies.removeAll());

  const handler = makeSpendHandler({ store: ctx.store, proxies, log: () => {} });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-9/v1/messages', {
      method: 'POST',
      body: '{}',
    }),
  );

  const files = await readdir(join(ctx.directory, 'spend'));

  expect(response.status).toBe(404);
  expect(files).toStrictEqual([]);
});

test('it answers the route of an ended preview with a 404', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 7 }, ['waiting'], { phase: 'ended' });

  const proxies = createSpendProxies(
    {
      proxyPath: ctx.stubPath,
      directory: join(ctx.directory, 'spend'),
      upstream: 'https://models.example.test',
      model: 'model-small',
      prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      limitDollars: 2,
      idleMs: 1_800_000,
    },
    ctx.deps,
  );

  onTestFinished(() => proxies.removeAll());

  const handler = makeSpendHandler({ store: ctx.store, proxies, log: () => {} });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body: '{}',
    }),
  );

  expect(response.status).toBe(404);
});

test('it refuses a preview model call with a 503 when its proxy cannot start', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  const proxies = createSpendProxies(
    {
      proxyPath: '/bin/false',
      directory: join(ctx.directory, 'spend'),
      upstream: 'https://models.example.test',
      model: 'model-small',
      prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      limitDollars: 2,
      idleMs: 1_800_000,
    },
    ctx.deps,
  );

  const handler = makeSpendHandler({ store: ctx.store, proxies, log: () => {} });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body: '{}',
    }),
  );

  const body: unknown = await response.json();

  expect(response.status).toBe(503);

  expect(body).toStrictEqual({
    type: 'error',
    error: { type: 'api_error', message: 'the preview service could not start the counting proxy' },
  });
});
