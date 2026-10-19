import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createUploadStore } from './create-upload-store.ts';
import { buildMockUpload } from './test-utils/build-mock-upload.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'files-store-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const store = createUploadStore(join(directory, 'files.db'));

  onTestFinished(() => {
    store.close();
  });

  return { directory, store };
}

test('it reads back every field of an upload it wrote', async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload({ label: 'release screenshot', link: 'https://example.com/pr/7' });

  ctx.store.writeUpload(upload);

  expect(ctx.store.findUpload(upload.id)).toStrictEqual(upload);
});

test('it reads back an upload with no label, no link and no expiry', async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload({ label: null, link: null, expiresAt: null, uploader: 'owner' });

  ctx.store.writeUpload(upload);

  expect(ctx.store.findUpload(upload.id)).toStrictEqual(upload);
});

test('it finds nothing for an id it never wrote', async () => {
  const ctx = await setupTest();

  expect(ctx.store.findUpload('Q0Q0Q0Q0Q0Q0Q0Q0Q0Q0Q0')).toBeNull();
});

test('it refuses a second upload with the same id', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(buildMockUpload({ id: 'Ab12Ab12Ab12Ab12Ab12Ab' }));

  expect(() => {
    ctx.store.writeUpload(buildMockUpload({ id: 'Ab12Ab12Ab12Ab12Ab12Ab' }));
  }).toThrow('UNIQUE constraint failed: uploads.id');
});

test('it lists one uploader newest first, and leaves out an expired upload', async () => {
  const ctx = await setupTest();

  const older = buildMockUpload({
    id: 'older0older0older0olde',
    createdAt: new Date('2026-05-01T10:00:00Z'),
    expiresAt: new Date('2026-05-08T10:00:00Z'),
  });

  const newer = buildMockUpload({
    id: 'newer0newer0newer0newe',
    createdAt: new Date('2026-05-02T10:00:00Z'),
    expiresAt: null,
  });

  const expired = buildMockUpload({
    id: 'gone00gone00gone00gone',
    createdAt: new Date('2026-04-01T10:00:00Z'),
    expiresAt: new Date('2026-05-03T00:00:00Z'),
  });

  const owner = buildMockUpload({ id: 'owner0owner0owner0owne', uploader: 'owner' });

  for (const upload of [older, newer, expired, owner]) {
    ctx.store.writeUpload(upload);
  }

  expect(
    ctx.store.collectUploads({
      uploader: 'agent',
      includeExpired: false,
      now: new Date('2026-05-03T00:00:00Z'),
    }),
  ).toStrictEqual([newer, older]);
});

test('it lists every uploader and the expired uploads when asked', async () => {
  const ctx = await setupTest();

  const agent = buildMockUpload({
    id: 'agent0agent0agent0agen',
    createdAt: new Date('2026-05-01T10:00:00Z'),
    expiresAt: new Date('2026-05-02T00:00:00Z'),
  });

  const owner = buildMockUpload({
    id: 'owner0owner0owner0owne',
    uploader: 'owner',
    createdAt: new Date('2026-05-02T10:00:00Z'),
  });

  ctx.store.writeUpload(agent);
  ctx.store.writeUpload(owner);

  expect(
    ctx.store.collectUploads({ includeExpired: true, now: new Date('2026-05-03T00:00:00Z') }),
  ).toStrictEqual([owner, agent]);
});

test('it breaks a tie in creation time by id', async () => {
  const ctx = await setupTest();

  const first = buildMockUpload({
    id: 'AAAAAAAAAAAAAAAAAAAAAA',
    createdAt: new Date('2026-05-01'),
  });

  const second = buildMockUpload({
    id: 'BBBBBBBBBBBBBBBBBBBBBB',
    createdAt: new Date('2026-05-01'),
  });

  ctx.store.writeUpload(first);
  ctx.store.writeUpload(second);

  expect(
    ctx.store.collectUploads({ includeExpired: true, now: new Date('2026-05-01') }),
  ).toStrictEqual([second, first]);
});

test('it changes an expiry to never', async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload();

  ctx.store.writeUpload(upload);
  ctx.store.updateExpiry(upload.id, null);

  expect(ctx.store.findUpload(upload.id)?.expiresAt).toBeNull();
});

test('it removes an upload', async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload();

  ctx.store.writeUpload(upload);
  ctx.store.removeUpload(upload.id);

  expect(ctx.store.findUpload(upload.id)).toBeNull();
});

test('it collects only the ids whose expiry is before now', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'past00past00past00past', expiresAt: new Date('2026-05-02T23:59:59Z') }),
  );

  ctx.store.writeUpload(
    buildMockUpload({ id: 'now000now000now000now0', expiresAt: new Date('2026-05-03T00:00:00Z') }),
  );

  ctx.store.writeUpload(buildMockUpload({ id: 'never0never0never0neve', expiresAt: null }));

  expect(ctx.store.collectExpiredIDs(new Date('2026-05-03T00:00:00Z'))).toStrictEqual([
    'past00past00past00past',
  ]);
});
