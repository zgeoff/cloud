import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPreviewStore } from './create-preview-store.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'preview-store-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const store = createPreviewStore(join(dir, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  return { dir, store };
}

test('it records a new pull request as waiting', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'waiting',
    detail: null,
  });
});

test('it moves the head of a ready preview and keeps the commit it built', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'ready',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toMatchObject({
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    phase: 'ready',
  });
});

test('it sets a reopened pull request waiting again', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'ended' });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('waiting');
});

test('it sets a failed preview waiting again and clears its failure when a push moves the head', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'failed',
    detail: 'the health URL never answered',
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    builtSHA: null,
    phase: 'waiting',
    detail: null,
  });
});

test('it keeps a failed preview failed when the same head arrives again', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], {
    phase: 'failed',
    detail: 'the health URL never answered',
  });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toMatchObject({
    phase: 'failed',
    detail: 'the health URL never answered',
  });
});

test('it refuses a phase change from a phase the preview is not in', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'ended' });

  const moved = ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
    phase: 'ready',
  });

  expect(moved).toBeFalse();
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('ended');
});

test('it keeps the previews across a reopen of the database file', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  const reopened = createPreviewStore(join(ctx.dir, 'previews.sqlite'));

  onTestFinished(() => {
    reopened.close();
  });

  expect(reopened.findPreview({ repo: 'acme/greenhouse', number: 17 })?.imp).toBe('pv-0a1b2c3d-17');
});

test('it fails the boots a stopped process left booting and leaves every other phase', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 18,
    imp: 'pv-0a1b2c3d-18',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });

  const failed = ctx.store.updateInterruptedBoots();

  expect(failed).toBe(1);

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })).toMatchObject({
    phase: 'failed',
    detail: 'the service stopped during the boot',
  });

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 18 })?.phase).toBe('waiting');
});

test('it returns null for a pull request it has not seen', async () => {
  const ctx = await setupTest();

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 99 })).toBeNull();
});

test('#claimContractRun records a queued run for a head commit and reports the claim', async () => {
  const ctx = await setupTest();

  const claimed = ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  expect(claimed).toBeTrue();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  ).toStrictEqual({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
    phase: 'queued',
    detail: null,
    outcome: null,
  });
});

test("#updateContractPhase records a settling run's result beside its phase", async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  ).toMatchObject({ phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' });
});

test('#claimContractRun refuses a second claim of one head commit and keeps the first run', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'passed', detail: '18 pass, 0 fail' },
  );

  const claimed = ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  expect(claimed).toBeFalse();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('passed');
});

test('#updateContractPhase refuses a change from a phase the run is not in', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  const moved = ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['running'],
    { phase: 'passed' },
  );

  expect(moved).toBeFalse();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('queued');
});

test('#collectContractRuns lists the runs at the given phases, oldest claim first', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    number: 18,
    imp: 'pv-sdk-bbbbbbbbbbbbbbbb',
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-aaaaaaaaaaaaaaaa',
  });

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'cccccccccccccccccccccccccccccccccccccccc',
    number: 19,
    imp: 'pv-sdk-cccccccccccccccc',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'waiting', detail: 'Waiting for a free preview slot' },
  );

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'cccccccccccccccccccccccccccccccccccccccc' },
    ['queued'],
    { phase: 'running' },
  );

  const runs = ctx.store.collectContractRuns(['queued', 'waiting']);

  expect(runs.map((run) => run.headSHA)).toStrictEqual([
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ]);
});

test('#updateInterruptedContractRuns queues again the runs a stopped process left running', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-aaaaaaaaaaaaaaaa',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['queued'],
    { phase: 'running' },
  );

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    number: 18,
    imp: 'pv-sdk-bbbbbbbbbbbbbbbb',
  });

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    ['queued'],
    { phase: 'failed', detail: '15 pass, 3 fail' },
  );

  const requeued = ctx.store.updateInterruptedContractRuns();

  expect(requeued).toBe(1);

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('queued');

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    })?.phase,
  ).toBe('failed');
});

test('#findContractRun returns null for a head commit it has not seen', async () => {
  const ctx = await setupTest();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  ).toBeNull();
});
