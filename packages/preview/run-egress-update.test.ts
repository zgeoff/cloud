import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { stubApp } from './mocks/github-app.ts';
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
    sleep: async () => {},
    log,
  };

  return { deps, impd, log };
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

  await runEgressUpdate(ctx.deps);

  expect(ctx.impd.egressModes).toStrictEqual(
    new Map([
      ['pv-0a1b2c3d-17', 'public'],
      ['pv-4e5f6a7b-3', 'public'],
    ]),
  );
});

test('it logs the failure and resolves when impd refuses the list', async () => {
  const ctx = await setupTest();

  const deps: PreviewDeps = {
    ...ctx.deps,
    impd: buildImpdClient(ctx.impd.url, 'imp_stubpreview.wrong-secret'),
  };

  await runEgressUpdate(deps);

  expect(ctx.log).toHaveBeenCalledWith(expect.toStartWith('the egress update failed: '));
});

test('it updates the other imps and logs the one whose update impd refuses', async () => {
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

  const deps: PreviewDeps = {
    ...ctx.deps,
    impd: {
      ...ctx.deps.impd,
      readImps: async () => [
        { name: 'pv-9c8d7e6f-2', state: 'sleeping', lastUsedAt: new Date('2026-10-14T08:00:00Z') },
        ...(await ctx.deps.impd.readImps()),
      ],
    },
  };

  await runEgressUpdate(deps);

  expect(ctx.impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-17', 'public']]));

  expect(ctx.log).toHaveBeenCalledWith(
    expect.toStartWith('pv-9c8d7e6f-2: the egress update failed: '),
  );
});
