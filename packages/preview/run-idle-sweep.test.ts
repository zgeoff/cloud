import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HttpResponse, http, passthrough } from 'msw';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { stubApp } from './mocks/github-app.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { server } from './mocks/node.ts';
import { runIdleSweep } from './run-idle-sweep.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-sweep-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();
  const log = mock<(message: string) => void>();

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
      impModelSecret: null,
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
      buildTimeoutMs: 1_800_000,
      contract: null,
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, stubApp, () => new Date()),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),

    now: () => new Date('2026-10-15T09:00:00Z'),
    sleep: async () => {},
    log,
  };

  return { deps, impd, log };
}

test('it sleeps the preview unused for the idle timeout and keeps the one in use', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.imps.set('pv-0a1b2c3d-18', {
    name: 'pv-0a1b2c3d-18',
    state: 'running',
    lastActiveAt: '2026-10-15T08:59:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  await runIdleSweep(ctx.deps);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-18')?.state).toBe('running');
});

test('it waits for a running boot to settle before it sleeps an idle preview', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const gate = Promise.withResolvers<void>();
  const held = ctx.deps.withSlotLock(() => gate.promise);
  const sweep = runIdleSweep(ctx.deps);

  // two impd round trips while the lock is held give an unlocked sweep time to list and sleep
  await ctx.deps.impd.readImps();
  await ctx.deps.impd.readImps();

  const stateWhileHeld = ctx.impd.imps.get('pv-0a1b2c3d-17')?.state;

  gate.resolve();

  await held;
  await sweep;

  expect(stateWhileHeld).toBe('running');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');
});

test('it sleeps the other idle previews when impd refuses one', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.imps.set('pv-0a1b2c3d-18', {
    name: 'pv-0a1b2c3d-18',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  server.use(
    http.post(`${ctx.impd.url}/rpc/imps/sleep`, async (info) => {
      const body = await info.request.clone().text();

      return body.includes('pv-0a1b2c3d-17')
        ? HttpResponse.json(
            {
              json: {
                defined: true,
                code: 'CONFLICT',
                status: 409,
                message: 'pv-0a1b2c3d-17 holds a lease',
              },
            },
            { status: 409 },
          )
        : passthrough();
    }),
  );

  await runIdleSweep(ctx.deps);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
  expect(ctx.impd.imps.get('pv-0a1b2c3d-18')?.state).toBe('sleeping');

  expect(ctx.log.mock.calls).toStrictEqual([
    [
      'pv-0a1b2c3d-17: the idle sleep failed: ImpdError: impd CONFLICT: pv-0a1b2c3d-17 holds a lease',
    ],
    ['pv-0a1b2c3d-18: asleep after the idle timeout'],
  ]);
});

test('it logs a failed sweep instead of throwing', async () => {
  const ctx = await setupTest();

  const deps = {
    ...ctx.deps,
    impd: buildImpdClient(ctx.impd.url, 'imp_wrong.token', NativeWebSocket),
  };

  await runIdleSweep(deps);

  expect(ctx.log).toHaveBeenCalledExactlyOnceWith(
    'the idle sweep failed: ImpdError: impd UNAUTHORIZED: missing or wrong token',
  );
});
