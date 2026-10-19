import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createUploadStore } from './create-upload-store.ts';
import { startExpirySweep } from './start-expiry-sweep.ts';
import { buildMockUpload } from './test-utils/build-mock-upload.ts';

async function setupTest() {
  const dataDir = await mkdtemp(join(tmpdir(), 'files-sweep-'));

  onTestFinished(() => rm(dataDir, { recursive: true, force: true }));

  const filesDir = join(dataDir, 'files');

  await mkdir(filesDir);

  const store = createUploadStore(join(dataDir, 'files.db'));

  onTestFinished(() => {
    store.close();
  });

  return { filesDir, store };
}

test('it removes an upload that expired before the start, file and row, at once', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'Gone0Gone0Gone0Gone0Go', expiresAt: new Date('2026-05-01T00:00:00Z') }),
  );

  await writeFile(join(ctx.filesDir, 'Gone0Gone0Gone0Gone0Go'), 'old');

  const print = mock<(line: string) => void>(() => {});

  startExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: () => new Date('2026-05-02T00:00:00Z'),
    print,
    schedule: () => () => {},
  });

  const files = await readdir(ctx.filesDir);

  expect(files).toBeEmpty();
  expect(ctx.store.findUpload('Gone0Gone0Gone0Gone0Go')).toBeNull();
  expect(print).toHaveBeenCalledExactlyOnceWith('expiry sweep: removed 1 uploads');
});

test('it schedules the next sweeps an hour apart', async () => {
  const ctx = await setupTest();

  const schedule = mock<(run: () => void, intervalMs: number) => () => void>(() => () => {});

  startExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: () => new Date('2026-05-02T00:00:00Z'),
    print: () => {},
    schedule,
  });

  expect(schedule).toHaveBeenCalledExactlyOnceWith(expect.toBeFunction(), 3_600_000);
});

test('it removes an upload that expires after the start when the scheduled sweep runs', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'Late0Late0Late0Late0La', expiresAt: new Date('2026-05-02T00:30:00Z') }),
  );

  await writeFile(join(ctx.filesDir, 'Late0Late0Late0Late0La'), 'later');

  const clock = { now: new Date('2026-05-02T00:00:00Z') };
  const schedule = mock<(run: () => void, intervalMs: number) => () => void>(() => () => {});

  startExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: () => clock.now,
    print: () => {},
    schedule,
  });

  const scheduledRun = schedule.mock.calls[0]?.[0];

  if (scheduledRun === undefined) {
    throw new Error('the sweep scheduled no run');
  }

  clock.now = new Date('2026-05-02T01:00:00Z');

  scheduledRun();

  const files = await readdir(ctx.filesDir);

  expect(files).toBeEmpty();
  expect(ctx.store.findUpload('Late0Late0Late0Late0La')).toBeNull();
});

test('it keeps an upload that has not expired, and one that never expires', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'Live0Live0Live0Live0Li', expiresAt: new Date('2026-05-09T00:00:00Z') }),
  );

  ctx.store.writeUpload(buildMockUpload({ id: 'Keep0Keep0Keep0Keep0Ke', expiresAt: null }));

  await writeFile(join(ctx.filesDir, 'Live0Live0Live0Live0Li'), 'live');
  await writeFile(join(ctx.filesDir, 'Keep0Keep0Keep0Keep0Ke'), 'keep');

  startExpirySweep({
    store: ctx.store,
    filesDir: ctx.filesDir,
    now: () => new Date('2026-05-02T00:00:00Z'),
    print: () => {},
    schedule: () => () => {},
  });

  const files = await readdir(ctx.filesDir);

  expect(files.toSorted()).toStrictEqual(['Keep0Keep0Keep0Keep0Ke', 'Live0Live0Live0Live0Li']);
});
