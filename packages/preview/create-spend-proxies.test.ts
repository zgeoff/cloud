import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { http, passthrough } from 'msw';
import { createSpendProxies } from './create-spend-proxies.ts';
import { server as mockServer } from './mocks/node.ts';
import { waitForCondition } from './test-utils/wait-for-condition.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'spend-proxies-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // each proxy's port comes from the kernel, so every loopback port passes through
  mockServer.use(http.all(/^http:\/\/127\.0\.0\.1:\d+\//u, () => passthrough()));

  const clock = { now: new Date('2026-10-15T09:00:00Z').getTime() };
  const lines: string[] = [];

  return {
    directory,
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

test('it starts a proxy for an imp with the imp as its one route and the limit and prices it was given', async () => {
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

  const hold = await proxies.holdProxy('pv-0a1b2c3d-7');

  const origin = hold.origin;

  const response = await fetch(`${origin}/pv-0a1b2c3d-7/v1/messages`, { method: 'POST' });
  const echo: unknown = await response.json();
  const config: unknown = await Bun.file(join(ctx.directory, 'spend', 'pv-0a1b2c3d-7.json')).json();

  expect(echo).toMatchObject({ path: '/pv-0a1b2c3d-7/v1/messages', routes: ['pv-0a1b2c3d-7'] });

  expect(config).toStrictEqual({
    listen: { hostname: '127.0.0.1', port: 0 },
    store: join(ctx.directory, 'spend', 'pv-0a1b2c3d-7.count.json'),
    limits: { dollars: 2 },
    routes: {
      'pv-0a1b2c3d-7': {
        upstream: 'https://models.example.test',
        model: 'model-small',
        prices: { input: 1, cache_write: 1.25, cache_write_1h: 2, cached_input: 0.1, output: 5 },
      },
    },
  });
});

test('it starts one proxy for two calls at once', async () => {
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

  const [first, second] = await Promise.all([
    proxies.holdProxy('pv-0a1b2c3d-7'),
    proxies.holdProxy('pv-0a1b2c3d-7'),
  ]);

  expect(second.origin).toBe(first.origin);
});

test('it starts a proxy again after the one it started exits', async () => {
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

  const first = await proxies.holdProxy('pv-0a1b2c3d-7');

  await fetch(`${first.origin}/exit`);
  await waitForCondition(() => ctx.lines.includes('pv-0a1b2c3d-7: the counting proxy exited 0'));

  const second = await proxies.holdProxy('pv-0a1b2c3d-7');
  const response = await fetch(`${second.origin}/pv-0a1b2c3d-7/v1/models`);

  expect(response.status).toBe(200);
});

test('it starts one proxy again for two calls that arrive together after it exits', async () => {
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

  const exited = await proxies.holdProxy('pv-0a1b2c3d-7');

  await fetch(`${exited.origin}/exit`);
  await waitForCondition(() => ctx.lines.includes('pv-0a1b2c3d-7: the counting proxy exited 0'));

  const [first, second] = await Promise.all([
    proxies.holdProxy('pv-0a1b2c3d-7'),
    proxies.holdProxy('pv-0a1b2c3d-7'),
  ]);

  expect(second.origin).toBe(first.origin);
});

test('it logs each later line of a proxy under the imp name', async () => {
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

  const hold = await proxies.holdProxy('pv-0a1b2c3d-7');

  const origin = hold.origin;

  await fetch(`${origin}/pv-0a1b2c3d-7/v1/models`);

  const logged = waitForCondition(() =>
    ctx.lines.includes('pv-0a1b2c3d-7: {"event":"request","path":"/pv-0a1b2c3d-7/v1/models"}'),
  );

  expect(logged).resolves.toBeUndefined();
});

test('it fails a call whose proxy never prints its start line', async () => {
  const ctx = await setupTest();

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

  expect(proxies.holdProxy('pv-0a1b2c3d-7')).rejects.toThrow(
    'the counting proxy for pv-0a1b2c3d-7 did not start',
  );
});

test('it removes a closed preview proxy with its config and its count', async () => {
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

  const hold = await proxies.holdProxy('pv-0a1b2c3d-7');

  const origin = hold.origin;

  await writeFile(
    join(ctx.directory, 'spend', 'pv-0a1b2c3d-7.count.json'),
    '{"dollars":1,"tokens":9}',
  );

  await proxies.removeProxy('pv-0a1b2c3d-7');

  const answer = await fetch(`${origin}/pv-0a1b2c3d-7/v1/models`).catch(() => null);
  const files = await readdir(join(ctx.directory, 'spend'));

  expect(answer).toBeNull();
  expect(files).toStrictEqual([]);
});

test('it stops a proxy unused for the idle time and keeps its count', async () => {
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

  const idle = await proxies.holdProxy('pv-0a1b2c3d-7');

  idle.release();

  ctx.clock.now += 1_200_000;

  const used = await proxies.holdProxy('pv-0a1b2c3d-8');

  used.release();

  await writeFile(
    join(ctx.directory, 'spend', 'pv-0a1b2c3d-7.count.json'),
    '{"dollars":1,"tokens":9}',
  );

  ctx.clock.now += 1_200_000;

  await proxies.removeIdle();

  const idleAnswer = await fetch(`${idle.origin}/pv-0a1b2c3d-7/v1/models`).catch(() => null);
  const usedAnswer = await fetch(`${used.origin}/pv-0a1b2c3d-8/v1/models`);
  const files = await readdir(join(ctx.directory, 'spend'));

  expect(idleAnswer).toBeNull();
  expect(usedAnswer.status).toBe(200);
  expect(files).toContain('pv-0a1b2c3d-7.count.json');
});

test('it keeps a proxy that holds a call past the idle time', async () => {
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

  const streaming = await proxies.holdProxy('pv-0a1b2c3d-7');

  ctx.clock.now += 2_400_000;

  await proxies.removeIdle();

  const answer = await fetch(`${streaming.origin}/pv-0a1b2c3d-7/v1/models`);

  expect(answer.status).toBe(200);
});
