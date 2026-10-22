import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { createPreviewStore } from './create-preview-store.ts';
import { createSpendProxies } from './create-spend-proxies.ts';
import { makeSpendHandler } from './make-spend-handler.ts';
import { server as mockServer } from './mocks/node.ts';
import { waitForCondition } from './test-utils/wait-for-condition.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'spend-handler-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // each proxy's port comes from the kernel, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const clock = { now: new Date('2026-10-15T09:00:00Z').getTime() };
  const lines: string[] = [];

  return {
    directory,
    store,
    clock,
    lines,
    stubPath: join(import.meta.dir, 'test-utils', 'run-stub-counting-proxy.ts'),
    deps: {
      now: () => new Date(clock.now),
      log: (line: string) => {
        lines.push(line);
      },
    },
  };
}

test('it keeps a preview proxy through an idle sweep while the proxy reply is unread', async () => {
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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body: '{"model":"model-small"}',
    }),
  );

  ctx.clock.now += 2_400_000;

  await proxies.removeIdle();

  const body: unknown = await response.json();

  expect(body).toMatchObject({ path: '/pv-0a1b2c3d-7/v1/messages' });
  expect(ctx.lines).not.toContain('pv-0a1b2c3d-7: the counting proxy exited 0');
});

test('it lets an idle sweep stop a preview proxy once the proxy reply is read', async () => {
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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body: '{"model":"model-small"}',
    }),
  );

  await response.text();

  ctx.clock.now += 2_400_000;

  await proxies.removeIdle();

  await waitForCondition(() => ctx.lines.includes('pv-0a1b2c3d-7: the counting proxy exited 0'));

  expect(ctx.lines).toContain('pv-0a1b2c3d-7: the counting proxy exited 0');
});

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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

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

test('it answers a 404 and starts no proxy when the preview closes while the call body arrives', async () => {
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

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies,
    sendRequest: fetch,
    log: () => {},
  });

  const opened = Promise.withResolvers<ReadableStreamDefaultController<Uint8Array>>();

  const body = new ReadableStream<Uint8Array>({
    start: (controller) => {
      opened.resolve(controller);
    },
  });

  const pending = handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body,
      duplex: 'half',
    }),
  );

  const controller = await opened.promise;

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 7 }, ['waiting'], { phase: 'ended' });
  controller.enqueue(new TextEncoder().encode('{"model":"model-small"}'));
  controller.close();

  const response = await pending;
  const files = await readdir(join(ctx.directory, 'spend'));

  expect(response.status).toBe(404);
  expect(files).toStrictEqual([]);
});

test('it answers a 502 and releases its hold when the started proxy refuses the call', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 7,
    imp: 'pv-0a1b2c3d-7',
    headSHA: 'c0ffee1',
  });

  const release = mock(() => {});

  const handler = makeSpendHandler({
    store: ctx.store,
    proxies: {
      holdProxy: () => Promise.resolve({ origin: 'http://127.0.0.1:1', release }),
      removeProxy: () => Promise.resolve(),
      removeIdle: () => Promise.resolve(),
      removeAll: () => Promise.resolve(),
    },
    sendRequest: fetch,
    log: () => {},
  });

  const response = await handler(
    new Request('http://172.17.0.1:18082/pv-0a1b2c3d-7/v1/messages', {
      method: 'POST',
      body: '{"model":"model-small"}',
    }),
  );

  const body: unknown = await response.json();

  expect(response.status).toBe(502);

  expect(body).toStrictEqual({
    type: 'error',
    error: { type: 'api_error', message: 'the counting proxy did not answer' },
  });

  expect(release).toHaveBeenCalledOnce();
});
