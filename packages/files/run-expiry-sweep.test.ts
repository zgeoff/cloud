import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createUploadStore } from './create-upload-store.ts';
import { runExpirySweep } from './run-expiry-sweep.ts';
import { buildMockUpload } from './test-utils/build-mock-upload.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'files-sweep-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const filesDir = join(directory, 'files');

  await mkdir(filesDir);

  const store = createUploadStore(join(directory, 'files.db'));

  onTestFinished(() => {
    store.close();
  });

  return { filesDir, store };
}

test('it removes the file and the row of an upload whose expiry has passed', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'old000old000old000old0', expiresAt: new Date('2026-05-01T00:00:00Z') }),
  );

  await writeFile(join(ctx.filesDir, 'old000old000old000old0'), 'expired bytes');

  const removed = runExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: new Date('2026-05-02T00:00:00Z'),
  });

  expect(removed).toStrictEqual(['old000old000old000old0']);

  const files = await readdir(ctx.filesDir);

  expect(files).toBeEmpty();
  expect(ctx.store.findUpload('old000old000old000old0')).toBeNull();
});

test('it never removes an upload that has not expired, or one that never expires', async () => {
  const ctx = await setupTest();

  const live = buildMockUpload({
    id: 'live00live00live00live',
    expiresAt: new Date('2026-05-09T00:00:00Z'),
  });

  const forever = buildMockUpload({ id: 'keep00keep00keep00keep', expiresAt: null });

  ctx.store.writeUpload(live);
  ctx.store.writeUpload(forever);

  await writeFile(join(ctx.filesDir, live.id), 'live bytes');
  await writeFile(join(ctx.filesDir, forever.id), 'kept bytes');

  const removed = runExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: new Date('2026-05-02T00:00:00Z'),
  });

  expect(removed).toBeEmpty();

  const files = await readdir(ctx.filesDir);

  expect(files).toIncludeSameMembers([live.id, forever.id]);
  expect(ctx.store.findUpload(live.id)).toStrictEqual(live);
  expect(ctx.store.findUpload(forever.id)).toStrictEqual(forever);
});

test('it removes the row of an expired upload whose file is already gone', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'half00half00half00half', expiresAt: new Date('2026-05-01T00:00:00Z') }),
  );

  const removed = runExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: new Date('2026-05-02T00:00:00Z'),
  });

  expect(removed).toStrictEqual(['half00half00half00half']);
  expect(ctx.store.findUpload('half00half00half00half')).toBeNull();
});
