/* oxlint-disable import/max-dependencies */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { runIdleSweep } from './run-idle-sweep.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-sweep-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();
  const log = mock();

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),
      slots: 1,

      // half an hour unused puts a preview to sleep
      idleMs: 1_800_000,
      impDomain: 'imps.example.test',
      impImage: 'base',
      impMemoryMib: 2048,
      impGitHubSecret: 'gh',
      healthTimeoutMs: 60_000,
      healthPollMs: 1000,
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),

    // the sweep runs at this moment
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
