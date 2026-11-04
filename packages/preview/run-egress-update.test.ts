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
import { server } from './mocks/node.ts';
import { runEgressUpdate } from './run-egress-update.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-egress-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();
  const log = mock<(message: string) => void>();
  const sleeps: number[] = [];

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
    spendProxies: null,
    store,
    impd: buildImpdClient(impd.url, impd.token),
    github: buildGitHubClient(githubAPIURL, stubApp, () => new Date()),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date('2026-10-15T09:00:00Z'),
    sleep: (durationMs) => {
      sleeps.push(durationMs);

      return Promise.resolve();
    },
    log,
  };

  return { deps, impd, log, sleeps, signal: new AbortController().signal };
}

test('it puts every imp impd lists, running or sleeping, under the public egress policy', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.imps.set('pv-4e5f6a7b-3', {
    name: 'pv-4e5f6a7b-3',
    state: 'sleeping',
    createdAt: '2026-09-02T00:00:00.000Z',
    lastActiveAt: '2026-10-14T08:00:00.000Z',
    lastRequestAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const updated = await runEgressUpdate(ctx.deps, ctx.signal);

  expect(updated).toBeTrue();

  expect(ctx.impd.egressModes).toStrictEqual(
    new Map([
      ['pv-0a1b2c3d-17', 'public'],
      ['pv-4e5f6a7b-3', 'public'],
    ]),
  );
});

test('it tries again after impd refuses the list, and updates every imp once the list answers', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  server.use(
    http.post(
      `${ctx.impd.url}/rpc/imps/list`,
      () =>
        HttpResponse.json(
          {
            json: {
              defined: false,
              code: 'SERVICE_UNAVAILABLE',
              status: 503,
              message: 'impd is starting',
            },
          },
          { status: 503 },
        ),
      { once: true },
    ),
  );

  const updated = await runEgressUpdate(ctx.deps, ctx.signal);

  expect(updated).toBeTrue();
  expect(ctx.impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-17', 'public']]));
  expect(ctx.sleeps).toStrictEqual([5000]);

  expect(ctx.log.mock.calls).toStrictEqual([
    ['the egress update failed: ImpdError: impd SERVICE_UNAVAILABLE: impd is starting'],
  ]);
});

test('it updates the other imps, then tries again the imp whose update impd refused', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.imps.set('pv-4e5f6a7b-3', {
    name: 'pv-4e5f6a7b-3',
    state: 'sleeping',
    createdAt: '2026-09-02T00:00:00.000Z',
    lastActiveAt: '2026-10-14T08:00:00.000Z',
    lastRequestAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const refused: string[] = [];

  server.use(
    http.post(`${ctx.impd.url}/rpc/imps/setPolicy`, async (info) => {
      const body = await info.request.clone().text();

      if (!body.includes('pv-4e5f6a7b-3') || refused.length > 0) {
        return passthrough();
      }

      refused.push('pv-4e5f6a7b-3');

      return HttpResponse.json(
        {
          json: {
            defined: true,
            code: 'MOVING',
            status: 409,
            message: 'The imp is moving between hosts',
            data: { retryAfterS: 5 },
          },
        },
        { status: 409 },
      );
    }),
  );

  const updated = await runEgressUpdate(ctx.deps, ctx.signal);

  expect(updated).toBeTrue();

  expect(ctx.impd.egressModes).toStrictEqual(
    new Map([
      ['pv-0a1b2c3d-17', 'public'],
      ['pv-4e5f6a7b-3', 'public'],
    ]),
  );

  expect(ctx.sleeps).toStrictEqual([5000]);

  expect(ctx.log.mock.calls).toStrictEqual([
    [
      'pv-4e5f6a7b-3: the egress update failed: ImpdError: impd MOVING: The imp is moving between hosts',
    ],
  ]);
});

test('it returns false, with no call to impd, once the signal has aborted', async () => {
  const ctx = await setupTest();
  const updated = await runEgressUpdate(ctx.deps, AbortSignal.abort());

  expect(updated).toBeFalse();
  expect(ctx.impd.calls).toStrictEqual([]);
});

test('it stops trying and returns false when the signal aborts during the wait for a retry', async () => {
  const ctx = await setupTest();

  const stop = new AbortController();

  const deps: PreviewDeps = {
    ...ctx.deps,
    impd: buildImpdClient(ctx.impd.url, 'imp_stubpreview.wrong-secret'),
    sleep: () => {
      stop.abort();

      return Promise.resolve();
    },
  };

  const updated = await runEgressUpdate(deps, stop.signal);

  expect(updated).toBeFalse();
  expect(ctx.impd.calls).toStrictEqual([]);
});
