import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { commitStatuses } from './mocks/github-state.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { runContractRetries } from './run-contract-retries.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';
import type { PreviewDeps } from './types.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-retries-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  const impd = startStubImpd();

  const deps: PreviewDeps = {
    settings: {
      baseURL: 'http://geoffcloud:8417',
      repos: new Set(['acme/greenhouse']),

      // two slots, so two waiting runs fit at once
      slots: 2,
      idleMs: 1_800_000,
      impDomain: impd.impDomain,
      impImage: 'pv-base',
      impMemoryMib: 4096,
      impGitHubSecret: null,
      impModelSecret: null,
      healthTimeoutMs: 600_000,
      healthPollMs: 2000,
      buildTimeoutMs: 1_800_000,
      contract: {
        repos: new Set(['acme/greenhouse']),
        modelSecret: 'model-haiku',
        timeoutMs: 600_000,
      },
    },
    store,
    impd: buildImpdClient(impd.url, impd.token, NativeWebSocket),
    github: buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token'),
    webhookSecret: 'stub-webhook-secret',
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date('2026-10-15T09:00:00Z'),

    // a run's deadline never passes, so each run ends with its guest command
    sleep: () => Promise.withResolvers<void>().promise,
    log: () => {},
  };

  return { deps, store, impd };
}

test('it tries every queued and waiting run again, and leaves an ended one alone', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-aaaaaaaaaaaaaaaa',
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    number: 18,
    imp: 'pv-sdk-bbbbbbbbbbbbbbbb',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    ['queued'],
    { phase: 'waiting', detail: 'Waiting for a free preview slot' },
  );

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'cccccccccccccccccccccccccccccccccccccccc',
    number: 19,
    imp: 'pv-sdk-cccccccccccccccc',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'cccccccccccccccccccccccccccccccccccccccc' },
    ['queued'],
    { phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'cccccccccccccccccccccccccccccccccccccccc' },
    ['settling'],
    { phase: 'failed', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  ctx.impd.answerCommand = () => ({ code: 0, stdout: ' 18 pass\n 0 fail\n' });

  runContractRetries(ctx.deps);

  await Promise.all(ctx.deps.pendingRuns);

  expect(
    commitStatuses.filter((status) => status.state === 'success').map((status) => status.sha),
  ).toIncludeSameMembers([
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  ]);

  expect(ctx.impd.commands.map((command) => command.imp)).toIncludeSameMembers([
    'pv-sdk-aaaaaaaaaaaaaaaa',
    'pv-sdk-bbbbbbbbbbbbbbbb',
  ]);
});
