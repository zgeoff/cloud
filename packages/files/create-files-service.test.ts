import { expect, onTestFinished, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFilesService } from './create-files-service.ts';
import { createUploadStore } from './create-upload-store.ts';
import { buildMockUpload } from './test-utils/build-mock-upload.ts';
import { buildUploadRequest } from './test-utils/build-upload-request.ts';

async function setupTest() {
  const dataDir = await mkdtemp(join(tmpdir(), 'files-service-'));

  onTestFinished(() => rm(dataDir, { recursive: true, force: true }));

  const store = createUploadStore(join(dataDir, 'files.db'));

  onTestFinished(() => {
    store.close();
  });

  const clock = { now: new Date() };

  const service = createFilesService({
    store,
    dataDir,
    tokenHashes: {
      agent: createHash('sha256').update('agent-token-5d2b').digest('hex'),
      owner: createHash('sha256').update('owner-token-c81f').digest('hex'),
    },
    publicURL: 'https://files.example.com',
    now: () => clock.now,
    readFreeBytes: () => Number.MAX_SAFE_INTEGER,
  });

  return { dataDir, store, clock, service };
}

test('it records an agent upload with the server-set fields and a 7-day expiry', async () => {
  const ctx = await setupTest();

  ctx.clock.now = new Date('2026-05-01T12:00:00Z');

  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x0d]);

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File([bytes], 'build log.png', { type: 'text/plain' }),
      fields: { label: 'login page', link: 'https://github.com/acme/app/pull/12' },
    }),
  );

  const body: unknown = await response.json();

  expect(response.status).toBe(201);

  expect(body).toStrictEqual({
    id: expect.toSatisfy((id: string) => /^[A-Za-z\d]{22}$/u.test(id)),
    url: expect.toSatisfy((url: string) =>
      /^https:\/\/files\.example\.com\/[A-Za-z\d]{22}\/build%20log\.png$/u.test(url),
    ),
    filename: 'build log.png',
    contentType: 'image/png',
    size: 10,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    createdAt: '2026-05-01T12:00:00.000Z',
    uploader: 'agent',
    label: 'login page',
    link: 'https://github.com/acme/app/pull/12',
    expiresAt: '2026-05-08T12:00:00.000Z',
  });
});

test('it names the owner as the uploader of an upload with the owner token', async () => {
  const ctx = await setupTest();

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer owner-token-c81f',
      file: new File(['notes'], 'notes.txt'),
      fields: { filename: 'renamed.txt' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toMatchObject({
    uploader: 'owner',
    filename: 'renamed.txt',
    label: null,
    link: null,
  });
});

test('it serves a PNG inline with nosniff and the sandbox policy', async () => {
  const ctx = await setupTest();

  const bytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x0d]);

  const upload = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File([bytes], 'shot.png'),
    }),
  );

  const uploaded = (await upload.json()) as { readonly url: string };

  const response = await ctx.service.handle(
    new Request(`http://localhost${new URL(uploaded.url).pathname}`),
  );

  expect(response.status).toBe(200);

  expect(Object.fromEntries(response.headers)).toMatchObject({
    'content-type': 'image/png',
    'content-disposition': `inline; filename="shot.png"; filename*=UTF-8''shot.png`,
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'none'; sandbox",
  });

  const served = await response.bytes();

  expect(served).toStrictEqual(bytes);
});

test('it serves an HTML upload as an octet-stream attachment, whatever type the uploader claimed', async () => {
  const ctx = await setupTest();

  const upload = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['<!doctype html><script>alert(1)</script>'], 'page.png', {
        type: 'image/png',
      }),
    }),
  );

  const uploaded = (await upload.json()) as { readonly url: string; readonly contentType: string };

  const response = await ctx.service.handle(
    new Request(`http://localhost${new URL(uploaded.url).pathname}`),
  );

  expect(uploaded.contentType).toBe('text/html');

  expect(Object.fromEntries(response.headers)).toMatchObject({
    'content-type': 'application/octet-stream',
    'content-disposition': `attachment; filename="page.png"; filename*=UTF-8''page.png`,
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'none'; sandbox",
  });
});

test('it serves an SVG upload as an attachment', async () => {
  const ctx = await setupTest();

  const upload = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>'], 'logo.svg'),
    }),
  );

  const uploaded = (await upload.json()) as { readonly url: string };

  const response = await ctx.service.handle(
    new Request(`http://localhost${new URL(uploaded.url).pathname}`),
  );

  expect(response.headers.get('content-disposition')).toStartWith('attachment;');
});

test('it answers 404 for a file once its expiry has passed', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({
      id: 'Exp1redExp1redExp1redE',
      filename: 'old.png',
      expiresAt: new Date('2026-05-08T12:00:00Z'),
    }),
  );

  await writeFile(join(ctx.dataDir, 'files', 'Exp1redExp1redExp1redE'), 'png bytes');

  ctx.clock.now = new Date('2026-05-08T12:00:00Z');

  const response = await ctx.service.handle(
    new Request('http://localhost/Exp1redExp1redExp1redE/old.png'),
  );

  expect(response.status).toBe(404);
  expect(response.headers.get('content-security-policy')).toBe("default-src 'none'; sandbox");
});

test('it serves a file until its expiry', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({
      id: 'L1veL1veL1veL1veL1veL1',
      filename: 'live.png',
      expiresAt: new Date('2026-05-08T12:00:00Z'),
    }),
  );

  await writeFile(join(ctx.dataDir, 'files', 'L1veL1veL1veL1veL1veL1'), 'png bytes');

  ctx.clock.now = new Date('2026-05-08T11:59:59.999Z');

  const response = await ctx.service.handle(
    new Request('http://localhost/L1veL1veL1veL1veL1veL1/live.png'),
  );

  expect(response.status).toBe(200);
});

test('it answers 404 for a live upload asked for under another filename', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'NameNameNameNameNameNa', filename: 'real.png', expiresAt: null }),
  );

  await writeFile(join(ctx.dataDir, 'files', 'NameNameNameNameNameNa'), 'png bytes');

  const response = await ctx.service.handle(
    new Request('http://localhost/NameNameNameNameNameNa/other.png'),
  );

  expect(response.status).toBe(404);
});

test('it answers 404 with nosniff and the sandbox policy on a path it does not serve', async () => {
  const ctx = await setupTest();
  const response = await ctx.service.handle(new Request('http://localhost/'));

  expect(response.status).toBe(404);

  expect(Object.fromEntries(response.headers)).toMatchObject({
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'none'; sandbox",
  });
});

test.each([
  ['an upload with no token', 'POST', '/api/files', {}],
  ['an upload with a wrong token', 'POST', '/api/files', { Authorization: 'Bearer wrong-0000' }],
  ['an expiry change with no token', 'POST', '/api/files/Own3rOwn3rOwn3rOwn3rOw/expire', {}],
  [
    'an expiry change with a wrong token',
    'POST',
    '/api/files/Own3rOwn3rOwn3rOwn3rOw/expire',
    { Authorization: 'Bearer wrong-0000' },
  ],
  ['a removal with no token', 'DELETE', '/api/files/Own3rOwn3rOwn3rOwn3rOw', {}],
  [
    'a removal with a wrong token',
    'DELETE',
    '/api/files/Own3rOwn3rOwn3rOwn3rOw',
    { Authorization: 'Bearer wrong-0000' },
  ],
])('it refuses %s with 401 and changes nothing', async (_name, method, path, headers) => {
  const ctx = await setupTest();

  const upload = buildMockUpload({ id: 'Own3rOwn3rOwn3rOwn3rOw', uploader: 'owner' });

  ctx.store.writeUpload(upload);

  const form = new FormData();

  form.append('file', new File(['bytes'], 'new.png'));
  form.append('expires', '30d');

  const init: RequestInit = { method, headers, body: form };

  const response = await ctx.service.handle(new Request(`http://localhost${path}`, init));

  expect(response.status).toBe(401);

  expect(ctx.store.collectUploads({ includeExpired: true, now: ctx.clock.now })).toStrictEqual([
    upload,
  ]);
});

test.each([
  ['a list', '/api/files'],
  ['an info read', '/api/files/Own3rOwn3rOwn3rOwn3rOw'],
])('it refuses %s without a token with 401', async (_name, path) => {
  const ctx = await setupTest();
  const response = await ctx.service.handle(new Request(`http://localhost${path}`));

  expect(response.status).toBe(401);
});

test('it refuses an agent upload that never expires with 403 and stores nothing', async () => {
  const ctx = await setupTest();

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['bytes'], 'keep.png'),
      fields: { expires: 'never' },
    }),
  );

  expect(response.status).toBe(403);

  const files = await readdir(join(ctx.dataDir, 'files'));

  expect(files).toBeEmpty();
});

test('it refuses an agent upload that expires more than 30 days away with 403', async () => {
  const ctx = await setupTest();

  ctx.clock.now = new Date('2026-05-01T12:00:00Z');

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['bytes'], 'keep.png'),
      fields: { expires: '2026-06-01' },
    }),
  );

  expect(response.status).toBe(403);
});

test('it lets an agent upload expire in 30 days', async () => {
  const ctx = await setupTest();

  ctx.clock.now = new Date('2026-05-01T12:00:00Z');

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['bytes'], 'month.png'),
      fields: { expires: '30d' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toMatchObject({ expiresAt: '2026-05-31T12:00:00.000Z' });
});

test('it lets the owner upload a file that never expires', async () => {
  const ctx = await setupTest();

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer owner-token-c81f',
      file: new File(['bytes'], 'keep.png'),
      fields: { expires: 'never' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toMatchObject({ expiresAt: null });
});

test('it refuses an expiry that names no time with 400', async () => {
  const ctx = await setupTest();

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer owner-token-c81f',
      file: new File(['bytes'], 'keep.png'),
      fields: { expires: 'someday' },
    }),
  );

  expect(response.status).toBe(400);
});

test('it refuses a filename with a slash with 400', async () => {
  const ctx = await setupTest();

  const response = await ctx.service.handle(
    buildUploadRequest({
      authorization: 'Bearer owner-token-c81f',
      file: new File(['bytes'], 'keep.png'),
      fields: { filename: '../keep.png' },
    }),
  );

  expect(response.status).toBe(400);
});

test('it refuses a file over 100 MB with 413 and stores nothing', async () => {
  const ctx = await setupTest();

  const file = new File([new Uint8Array(100_000_001)], 'big.bin');

  const response = await ctx.service.handle(
    buildUploadRequest({ authorization: 'Bearer owner-token-c81f', file }),
  );

  expect(response.status).toBe(413);

  const files = await readdir(join(ctx.dataDir, 'files'));

  expect(files).toBeEmpty();
});

test('it refuses an upload with 507 when the volume is full', async () => {
  const ctx = await setupTest();

  const service = createFilesService({
    store: ctx.store,
    dataDir: ctx.dataDir,
    tokenHashes: {
      agent: createHash('sha256').update('agent-token-5d2b').digest('hex'),
      owner: createHash('sha256').update('owner-token-c81f').digest('hex'),
    },
    publicURL: 'https://files.example.com',
    now: () => ctx.clock.now,
    readFreeBytes: () => 1_000_000,
  });

  const response = await service.handle(
    buildUploadRequest({
      authorization: 'Bearer agent-token-5d2b',
      file: new File(['bytes'], 'shot.png'),
    }),
  );

  expect(response.status).toBe(507);

  const files = await readdir(join(ctx.dataDir, 'files'));

  expect(files).toBeEmpty();
});

test('it lists only agent uploads for the agent token', async () => {
  const ctx = await setupTest();

  const agent = buildMockUpload({
    id: 'Ag3ntAg3ntAg3ntAg3ntAg',
    uploader: 'agent',
    expiresAt: null,
  });

  ctx.store.writeUpload(agent);
  ctx.store.writeUpload(buildMockUpload({ id: 'Own3rOwn3rOwn3rOwn3rOw', uploader: 'owner' }));

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files', {
      headers: { Authorization: 'Bearer agent-token-5d2b' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual([expect.objectContaining({ id: 'Ag3ntAg3ntAg3ntAg3ntAg' })]);
});

test('it lists every uploader for the owner token, with the expired uploads when asked', async () => {
  const ctx = await setupTest();

  ctx.clock.now = new Date('2026-05-10T00:00:00Z');

  ctx.store.writeUpload(
    buildMockUpload({
      id: 'Ag3ntAg3ntAg3ntAg3ntAg',
      createdAt: new Date('2026-05-01T00:00:00Z'),
      expiresAt: new Date('2026-05-08T00:00:00Z'),
    }),
  );

  ctx.store.writeUpload(
    buildMockUpload({
      id: 'Own3rOwn3rOwn3rOwn3rOw',
      uploader: 'owner',
      createdAt: new Date('2026-05-02T00:00:00Z'),
      expiresAt: null,
    }),
  );

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files?includeExpired=true', {
      headers: { Authorization: 'Bearer owner-token-c81f' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual([
    expect.objectContaining({ id: 'Own3rOwn3rOwn3rOwn3rOw' }),
    expect.objectContaining({ id: 'Ag3ntAg3ntAg3ntAg3ntAg' }),
  ]);
});

test('it shows an agent upload to the owner token', async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload({
    id: 'Ag3ntAg3ntAg3ntAg3ntAg',
    filename: 'shot.png',
    contentType: 'image/png',
    size: 4,
    sha256: 'f'.repeat(64),
    createdAt: new Date('2026-05-01T00:00:00Z'),
    uploader: 'agent',
    label: null,
    link: null,
    expiresAt: new Date('2026-05-08T00:00:00Z'),
  });

  ctx.store.writeUpload(upload);

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Ag3ntAg3ntAg3ntAg3ntAg', {
      headers: { Authorization: 'Bearer owner-token-c81f' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    id: 'Ag3ntAg3ntAg3ntAg3ntAg',
    url: 'https://files.example.com/Ag3ntAg3ntAg3ntAg3ntAg/shot.png',
    filename: 'shot.png',
    contentType: 'image/png',
    size: 4,
    sha256: 'f'.repeat(64),
    createdAt: '2026-05-01T00:00:00.000Z',
    uploader: 'agent',
    label: null,
    link: null,
    expiresAt: '2026-05-08T00:00:00.000Z',
  });
});

test('it hides an owner upload from the agent token with 404', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(buildMockUpload({ id: 'Own3rOwn3rOwn3rOwn3rOw', uploader: 'owner' }));

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Own3rOwn3rOwn3rOwn3rOw', {
      headers: { Authorization: 'Bearer agent-token-5d2b' },
    }),
  );

  expect(response.status).toBe(404);
});

test('it lets the agent token remove an agent upload, file and row', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(
    buildMockUpload({ id: 'Ag3ntAg3ntAg3ntAg3ntAg', filename: 'shot.png', expiresAt: null }),
  );

  await writeFile(join(ctx.dataDir, 'files', 'Ag3ntAg3ntAg3ntAg3ntAg'), 'png bytes');

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Ag3ntAg3ntAg3ntAg3ntAg', {
      method: 'DELETE',
      headers: { Authorization: 'Bearer agent-token-5d2b' },
    }),
  );

  const body: unknown = await response.json();

  expect(body).toStrictEqual({ id: 'Ag3ntAg3ntAg3ntAg3ntAg' });

  const files = await readdir(join(ctx.dataDir, 'files'));

  expect(files).toBeEmpty();
  expect(ctx.store.findUpload('Ag3ntAg3ntAg3ntAg3ntAg')).toBeNull();
});

test("it refuses the agent token's removal of an owner upload with 404 and keeps it", async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload({ id: 'Own3rOwn3rOwn3rOwn3rOw', uploader: 'owner' });

  ctx.store.writeUpload(upload);

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Own3rOwn3rOwn3rOwn3rOw', {
      method: 'DELETE',
      headers: { Authorization: 'Bearer agent-token-5d2b' },
    }),
  );

  expect(response.status).toBe(404);
  expect(ctx.store.findUpload('Own3rOwn3rOwn3rOwn3rOw')).toStrictEqual(upload);
});

test('it lets the owner token keep an agent upload forever', async () => {
  const ctx = await setupTest();

  ctx.store.writeUpload(buildMockUpload({ id: 'Ag3ntAg3ntAg3ntAg3ntAg' }));

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Ag3ntAg3ntAg3ntAg3ntAg/expire', {
      method: 'POST',
      headers: { Authorization: 'Bearer owner-token-c81f', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expires: 'never' }),
    }),
  );

  const body: unknown = await response.json();

  expect(body).toMatchObject({ expiresAt: null });
  expect(ctx.store.findUpload('Ag3ntAg3ntAg3ntAg3ntAg')?.expiresAt).toBeNull();
});

test("it refuses the agent token's change of an expiry with 403", async () => {
  const ctx = await setupTest();

  const upload = buildMockUpload({ id: 'Ag3ntAg3ntAg3ntAg3ntAg' });

  ctx.store.writeUpload(upload);

  const response = await ctx.service.handle(
    new Request('http://localhost/api/files/Ag3ntAg3ntAg3ntAg3ntAg/expire', {
      method: 'POST',
      headers: { Authorization: 'Bearer agent-token-5d2b', 'Content-Type': 'application/json' },
      body: JSON.stringify({ expires: '7d' }),
    }),
  );

  expect(response.status).toBe(403);
  expect(ctx.store.findUpload('Ag3ntAg3ntAg3ntAg3ntAg')).toStrictEqual(upload);
});

test('it removes a file that a stopped run left half written', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dataDir, 'incoming'), { recursive: true });
  await writeFile(join(ctx.dataDir, 'incoming', 'Half0Half0Half0Half0Ha'), 'part');

  createFilesService({
    store: ctx.store,
    dataDir: ctx.dataDir,
    tokenHashes: {
      agent: createHash('sha256').update('agent-token-5d2b').digest('hex'),
      owner: createHash('sha256').update('owner-token-c81f').digest('hex'),
    },
    publicURL: 'https://files.example.com',
    now: () => ctx.clock.now,
    readFreeBytes: () => Number.MAX_SAFE_INTEGER,
  });

  const incoming = await readdir(join(ctx.dataDir, 'incoming'));

  expect(incoming).toBeEmpty();
});
