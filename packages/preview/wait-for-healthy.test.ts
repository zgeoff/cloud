/* oxlint-disable import/max-dependencies */
import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
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
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
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

test('it resolves true at the first probe the health path answers', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  const healthy = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 3000,
  });

  expect(healthy).toBeTrue();

  expect(ctx.impd.commands).toStrictEqual([
    {
      imp: 'pv-0a1b2c3d-17',
      argv: [
        'curl',
        '--fail',
        '--silent',
        '--output',
        '/dev/null',
        '--max-time',
        '5',
        'http://127.0.0.1:3000/healthz',
      ],
      require: [],
    },
  ]);
});

test('it resolves false after the probes that fit in the window all fail', async () => {
  const ctx = await setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    lastActiveAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  ctx.impd.answerCommand = () => ({ code: 7 });

  const healthy = await waitForHealthy(ctx.deps, {
    imp: 'pv-0a1b2c3d-17',
    contract: { port: 3000, healthPath: '/healthz' },
    windowMs: 3000,
  });

  expect(healthy).toBeFalse();
  expect(ctx.impd.commands).toHaveLength(3);
});
