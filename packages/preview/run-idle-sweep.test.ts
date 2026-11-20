import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { runIdleSweep } from './run-idle-sweep.ts';
import { githubAPIURL } from './src/test-utils/github-api-url.ts';
import { startPreviewImpd } from './src/test-utils/start-preview-impd.ts';
import { startStubImpd } from './src/test-utils/start-stub-impd.ts';
import { stubApp } from './src/test-utils/stub-app.ts';
import { waitForCondition } from './src/test-utils/wait-for-condition.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest<Impd extends { readonly url: string; readonly token: string }>(
  impd: Impd,
) {
  const nowAt = new Date('2026-10-15T09:00:00Z');

  const directory = await mkdtemp(join(tmpdir(), 'preview-sweep-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

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
      impMaxMemoryMib: 2048,
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

    now: () => nowAt,
    sleep: async () => {},
    log,
  };

  return { deps, impd, log };
}

test('it sleeps the preview unused for the idle timeout and keeps the one in use', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-17', grants: ['gh'] });

  const first = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-17' });

  // impd times each imp as it creates it, so the second one is used later than the first
  await waitForCondition(() => Date.now() > first.lastActiveAt.getTime() + 5);

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-18', grants: ['gh'] });

  const nowAt = new Date(first.lastActiveAt.getTime() + ctx.deps.settings.idleMs + 1);

  await runIdleSweep({ ...ctx.deps, now: () => nowAt });

  const states = await ctx.impd.client.imps.list({});

  expect(states.map((imp) => [imp.name, imp.state])).toStrictEqual([
    ['pv-0a1b2c3d-17', 'sleeping'],
    ['pv-0a1b2c3d-18', 'running'],
  ]);
});

test('it sleeps a preview whose busy stack keeps impd counting it active once no request has come through the proxy for the idle timeout', async () => {
  const ctx = await setupTest(startStubImpd({ now: () => new Date('2026-10-15T09:00:00Z') }));

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-10-15T07:00:00.000Z',
    lastActiveAt: '2026-10-15T09:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  await runIdleSweep(ctx.deps);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('sleeping');
});

test('it keeps a preview in use awake past the idle timeout from its creation on an impd that reports no request time', async () => {
  const ctx = await setupTest(startStubImpd({ now: () => new Date('2026-10-15T09:00:00Z') }));

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-10-15T08:00:00.000Z',
    lastActiveAt: '2026-10-15T08:59:00.000Z',
    lastRequestAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  await runIdleSweep(ctx.deps);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

test('it keeps a preview awake after a request through the proxy resets its idle time', async () => {
  const ctx = await setupTest(startStubImpd({ now: () => new Date('2026-10-15T09:00:00Z') }));

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-10-15T07:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.apps.set('pv-0a1b2c3d-17', { address: '0.0.0.0', port: 8080 });

  await fetch(`https://pv-0a1b2c3d-17.${ctx.impd.impDomain}/`);
  await runIdleSweep(ctx.deps);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-17')?.state).toBe('running');
});

test('it waits for a running boot to settle before it sleeps an idle preview', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-17', grants: ['gh'] });

  const gate = Promise.withResolvers<void>();
  const held = ctx.deps.withSlotLock(() => gate.promise);
  const sweep = runIdleSweep({ ...ctx.deps, now: () => new Date(Date.now() + 3_600_000) });

  // two impd round trips while the lock is held give an unlocked sweep time to list and sleep
  await ctx.deps.impd.readImps();
  await ctx.deps.impd.readImps();

  const impWhileHeld = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-17' });

  const stateWhileHeld = impWhileHeld.state;

  gate.resolve();

  await held;
  await sweep;

  expect(stateWhileHeld).toBe('running');

  const heldImp = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-17' });

  expect(heldImp.state).toBe('sleeping');
});

test('it sleeps the other idle previews when impd refuses one', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-17', grants: ['gh'] });
  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-18', grants: ['gh'] });

  ctx.impd.fail(
    'imps/sleep',
    { code: 'CONFLICT', status: 409, message: 'pv-0a1b2c3d-17 holds a lease' },
    { when: (input) => JSON.stringify(input).includes('pv-0a1b2c3d-17') },
  );

  await runIdleSweep({ ...ctx.deps, now: () => new Date(Date.now() + 3_600_000) });

  const states = await ctx.impd.client.imps.list({});

  expect(states.map((imp) => [imp.name, imp.state])).toStrictEqual([
    ['pv-0a1b2c3d-17', 'running'],
    ['pv-0a1b2c3d-18', 'sleeping'],
  ]);

  expect(ctx.log.mock.calls).toStrictEqual([
    [
      'pv-0a1b2c3d-17: the idle sleep failed: ImpdError: impd CONFLICT: pv-0a1b2c3d-17 holds a lease',
    ],
    ['pv-0a1b2c3d-18: asleep after the idle timeout'],
  ]);
});

test('it logs a failed sweep instead of throwing', async () => {
  const impd = startPreviewImpd();

  const ctx = await setupTest(impd);

  const deps = {
    ...ctx.deps,
    impd: buildImpdClient(ctx.impd.url, 'imp_wrong.token'),
  };

  await runIdleSweep(deps);

  expect(ctx.log).toHaveBeenCalledExactlyOnceWith(
    'the idle sweep failed: ImpdError: impd UNAUTHORIZED: Unauthorized',
  );
});
