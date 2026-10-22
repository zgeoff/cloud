import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ContractRun, Preview } from './create-preview-store.ts';
import { createPreviewStore } from './create-preview-store.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-store-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createPreviewStore(join(directory, 'previews.sqlite'));

  onTestFinished(() => {
    store.close();
  });

  return { directory, store };
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

test('#findPreviewByImp finds a preview by the name of its imp', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  expect(ctx.store.findPreviewByImp('pv-0a1b2c3d-17')).toStrictEqual({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    builtSHA: null,
    phase: 'waiting',
    detail: null,
  });
});

test('#findPreviewByImp returns null for an imp no preview holds', async () => {
  const ctx = await setupTest();

  expect(ctx.store.findPreviewByImp('pv-0a1b2c3d-17')).toBeNull();
});

test('it moves the head of a ready preview and keeps the commit it built', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
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

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
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

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting'], {
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

test.each<[Preview['phase'], Preview['phase'], [Preview['phase'], Preview['phase']][]]>([
  ['waiting', 'booting', []],
  ['waiting', 'ended', []],
  ['booting', 'ready', [['waiting', 'booting']]],
  ['booting', 'failed', [['waiting', 'booting']]],
  ['booting', 'waiting', [['waiting', 'booting']]],
  ['booting', 'ended', [['waiting', 'booting']]],
  [
    'ready',
    'booting',
    [
      ['waiting', 'booting'],
      ['booting', 'ready'],
    ],
  ],
  [
    'ready',
    'ended',
    [
      ['waiting', 'booting'],
      ['booting', 'ready'],
    ],
  ],
  [
    'failed',
    'booting',
    [
      ['waiting', 'booting'],
      ['booting', 'failed'],
    ],
  ],
  [
    'failed',
    'waiting',
    [
      ['waiting', 'booting'],
      ['booting', 'failed'],
    ],
  ],
  [
    'failed',
    'ended',
    [
      ['waiting', 'booting'],
      ['booting', 'failed'],
    ],
  ],
  ['ended', 'waiting', [['waiting', 'ended']]],
])('it moves a preview from %s to %s', async (from, to, path) => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  for (const [before, after] of path) {
    ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, [before], { phase: after });
  }

  const moved = ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, [from], {
    phase: to,
  });

  expect(moved).toBeTrue();
  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe(to);
});

test.each<[Preview['phase'], Preview['phase'], [Preview['phase'], Preview['phase']][]]>([
  ['waiting', 'waiting', []],
  ['waiting', 'ready', []],
  ['waiting', 'failed', []],
  ['booting', 'booting', [['waiting', 'booting']]],
  [
    'ready',
    'waiting',
    [
      ['waiting', 'booting'],
      ['booting', 'ready'],
    ],
  ],
  [
    'ready',
    'ready',
    [
      ['waiting', 'booting'],
      ['booting', 'ready'],
    ],
  ],
  [
    'ready',
    'failed',
    [
      ['waiting', 'booting'],
      ['booting', 'ready'],
    ],
  ],
  [
    'failed',
    'ready',
    [
      ['waiting', 'booting'],
      ['booting', 'failed'],
    ],
  ],
  [
    'failed',
    'failed',
    [
      ['waiting', 'booting'],
      ['booting', 'failed'],
    ],
  ],
  ['ended', 'booting', [['waiting', 'ended']]],
  ['ended', 'ready', [['waiting', 'ended']]],
  ['ended', 'failed', [['waiting', 'ended']]],
  ['ended', 'ended', [['waiting', 'ended']]],
])(
  'it refuses to move a preview from %s to %s, a move the phase table lacks',
  async (from, to, path) => {
    const ctx = await setupTest();

    ctx.store.upsertHead({
      repo: 'acme/greenhouse',
      number: 17,
      imp: 'pv-0a1b2c3d-17',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });

    for (const [before, after] of path) {
      ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, [before], { phase: after });
    }

    expect(() =>
      ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, [from], { phase: to }),
    ).toThrowWithMessage(Error, `a preview cannot move from ${from} to ${to}`);

    expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe(from);
  },
);

test('it refuses a phase change when any of its from phases lacks the move', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['waiting'], { phase: 'booting' });

  expect(() =>
    ctx.store.updatePhase({ repo: 'acme/greenhouse', number: 17 }, ['booting', 'ended'], {
      phase: 'ready',
      builtSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  ).toThrowWithMessage(Error, 'a preview cannot move from ended to ready');

  expect(ctx.store.findPreview({ repo: 'acme/greenhouse', number: 17 })?.phase).toBe('booting');
});

test('it keeps the previews across a reopen of the database file', async () => {
  const ctx = await setupTest();

  ctx.store.upsertHead({
    repo: 'acme/greenhouse',
    number: 17,
    imp: 'pv-0a1b2c3d-17',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  const reopened = createPreviewStore(join(ctx.directory, 'previews.sqlite'));

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
    { phase: 'settling', detail: '18 pass, 0 fail', outcome: 'success' },
  );

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    ['settling'],
    { phase: 'passed', detail: '18 pass, 0 fail', outcome: 'success' },
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
    { phase: 'settling', detail: '18 pass, 0 fail', outcome: 'success' },
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
    { phase: 'settling', detail: '15 pass, 3 fail', outcome: 'failure' },
  );

  ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
    ['settling'],
    { phase: 'failed', detail: '15 pass, 3 fail', outcome: 'failure' },
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

test.each<
  [ContractRun['phase'], ContractRun['phase'], [ContractRun['phase'], ContractRun['phase']][]]
>([
  ['queued', 'waiting', []],
  ['queued', 'running', []],
  ['queued', 'settling', []],
  ['waiting', 'running', [['queued', 'waiting']]],
  ['waiting', 'settling', [['queued', 'waiting']]],
  ['running', 'settling', [['queued', 'running']]],
  ['running', 'queued', [['queued', 'running']]],
  ['settling', 'passed', [['queued', 'settling']]],
  ['settling', 'failed', [['queued', 'settling']]],
])('#updateContractPhase moves a run from %s to %s', async (from, to, path) => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  for (const [before, after] of path) {
    ctx.store.updateContractPhase(
      { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
      [before],
      { phase: after },
    );
  }

  const moved = ctx.store.updateContractPhase(
    { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    [from],
    { phase: to },
  );

  expect(moved).toBeTrue();

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe(to);
});

test.each<
  [ContractRun['phase'], ContractRun['phase'], [ContractRun['phase'], ContractRun['phase']][]]
>([
  ['queued', 'queued', []],
  ['queued', 'passed', []],
  ['queued', 'failed', []],
  ['waiting', 'queued', [['queued', 'waiting']]],
  ['waiting', 'waiting', [['queued', 'waiting']]],
  ['waiting', 'passed', [['queued', 'waiting']]],
  ['waiting', 'failed', [['queued', 'waiting']]],
  ['running', 'waiting', [['queued', 'running']]],
  ['running', 'running', [['queued', 'running']]],
  ['running', 'passed', [['queued', 'running']]],
  ['running', 'failed', [['queued', 'running']]],
  ['settling', 'queued', [['queued', 'settling']]],
  ['settling', 'waiting', [['queued', 'settling']]],
  ['settling', 'running', [['queued', 'settling']]],
  ['settling', 'settling', [['queued', 'settling']]],
  [
    'passed',
    'queued',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'passed',
    'waiting',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'passed',
    'running',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'passed',
    'settling',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'passed',
    'passed',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'passed',
    'failed',
    [
      ['queued', 'settling'],
      ['settling', 'passed'],
    ],
  ],
  [
    'failed',
    'queued',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
  [
    'failed',
    'waiting',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
  [
    'failed',
    'running',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
  [
    'failed',
    'settling',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
  [
    'failed',
    'passed',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
  [
    'failed',
    'failed',
    [
      ['queued', 'settling'],
      ['settling', 'failed'],
    ],
  ],
])(
  '#updateContractPhase refuses to move a run from %s to %s, a move the contract phase table lacks',
  async (from, to, path) => {
    const ctx = await setupTest();

    ctx.store.claimContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      number: 17,
      imp: 'pv-sdk-0123456789abcdef',
    });

    for (const [before, after] of path) {
      ctx.store.updateContractPhase(
        { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
        [before],
        { phase: after },
      );
    }

    expect(() =>
      ctx.store.updateContractPhase(
        { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
        [from],
        { phase: to },
      ),
    ).toThrowWithMessage(Error, `a contract run cannot move from ${from} to ${to}`);

    expect(
      ctx.store.findContractRun({
        repo: 'acme/greenhouse',
        headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      })?.phase,
    ).toBe(from);
  },
);

test('#updateContractPhase refuses a change when any of its from phases lacks the move', async () => {
  const ctx = await setupTest();

  ctx.store.claimContractRun({
    repo: 'acme/greenhouse',
    headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    number: 17,
    imp: 'pv-sdk-0123456789abcdef',
  });

  expect(() =>
    ctx.store.updateContractPhase(
      { repo: 'acme/greenhouse', headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
      ['running', 'queued'],
      { phase: 'queued' },
    ),
  ).toThrowWithMessage(Error, 'a contract run cannot move from queued to queued');

  expect(
    ctx.store.findContractRun({
      repo: 'acme/greenhouse',
      headSHA: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    })?.phase,
  ).toBe('queued');
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
