/* oxlint-disable import/max-dependencies, max-lines-per-function */
import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http } from 'msw';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { server } from './mocks/node.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';
import { waitForHealthy } from './wait-for-healthy.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-health-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();

  // a clock that each pause between health probes moves on
  const clock = { now: new Date('2026-10-15T09:00:00Z').getTime() };

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 60_000,

      // one second between probes
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date(clock.now),
    sleep: (ms) => {
      clock.now += ms;

      return Promise.resolve();
    },
    log: () => {},
  };

  return { deps, impd };
}

test("it resolves healthy at the first probe through impd's proxy that the health path answers", async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 3000 });

  const health = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 3000,
  });

  expect(health).toStrictEqual({
    healthy: true,
    url: 'https://pv-0a1b2c3d-17.imps.example.test/healthz',
    lastAnswer: null,
  });

  expect(ctx.impd.proxied).toStrictEqual(['GET https://pv-0a1b2c3d-17.imps.example.test/healthz']);
  expect(ctx.impd.commands).toStrictEqual([]);
});

test("it resolves unhealthy with the proxy's last answer when the app listens on the guest's loopback alone", async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '127.0.0.1', port: 3000 });

  const health = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 3000,
  });

  expect(health).toStrictEqual({
    healthy: false,
    url: 'https://pv-0a1b2c3d-17.imps.example.test/healthz',
    lastAnswer:
      '502 Nothing answers in the imp: pv-0a1b2c3d-17 is awake, but nothing answered on port 3000 (Unable to connect. Is the computer able to access the url?).',
  });

  expect(ctx.impd.proxied).toBeArrayOfSize(3);
});

test("it resolves unhealthy with the error when the imp's name never answers", async () => {
  const ctx = await setupTest();

  server.use(
    http.get('https://pv-0a1b2c3d-17.imps.example.test/healthz', () => HttpResponse.error()),
  );

  const health = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 1000,
  });

  expect(health).toStrictEqual({
    healthy: false,
    url: 'https://pv-0a1b2c3d-17.imps.example.test/healthz',
    lastAnswer: 'Failed to fetch',
  });
});

test('it counts a redirect from the health path as healthy, as curl --fail did', async () => {
  const ctx = await setupTest();

  server.use(
    http.get('https://pv-0a1b2c3d-17.imps.example.test/healthz', () =>
      HttpResponse.redirect('https://pv-0a1b2c3d-17.imps.example.test/login', 302),
    ),
  );

  const health = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 1000,
  });

  expect(health).toStrictEqual({
    healthy: true,
    url: 'https://pv-0a1b2c3d-17.imps.example.test/healthz',
    lastAnswer: null,
  });
});

test('it keeps the status and the text of a plain answer that is not healthy', async () => {
  const ctx = await setupTest();

  server.use(
    http.get('https://pv-0a1b2c3d-17.imps.example.test/healthz', () =>
      HttpResponse.text('  still seeding\n  the invented orders\n', { status: 503 }),
    ),
  );

  const health = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 1000,
  });

  expect(health).toStrictEqual({
    healthy: false,
    url: 'https://pv-0a1b2c3d-17.imps.example.test/healthz',
    lastAnswer: '503 still seeding the invented orders',
  });
});
