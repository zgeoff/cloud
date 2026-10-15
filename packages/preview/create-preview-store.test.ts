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
