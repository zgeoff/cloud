import { expect, test } from 'bun:test';
import { buildMockUpload } from './build-mock-upload.ts';

test('it builds a default upload', () => {
  const upload = buildMockUpload();

  expect(upload).toStrictEqual({
    id: expect.toSatisfy((id: string) => /^[A-Za-z\d]{22}$/u.test(id)),
    filename: expect.toEndWith('.png'),
    contentType: 'image/png',
    size: expect.toBeWithin(1, 1_000_001),
    sha256: expect.toSatisfy((hash: string) => /^[\da-f]{64}$/u.test(hash)),
    createdAt: expect.toBeValidDate(),
    uploader: 'agent',
    label: expect.toBeString(),
    link: expect.toStartWith('http'),
    expiresAt: new Date(upload.createdAt.getTime() + 604_800_000),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockUpload({
      id: 'Zx81Zx81Zx81Zx81Zx81Zx',
      uploader: 'owner',
      label: null,
      expiresAt: null,
    }),
  ).toMatchObject({
    id: 'Zx81Zx81Zx81Zx81Zx81Zx',
    uploader: 'owner',
    label: null,
    expiresAt: null,
  });
});

test('it expires a week after the creation time it is given', () => {
  expect(buildMockUpload({ createdAt: new Date('2026-03-01T09:00:00Z') }).expiresAt).toStrictEqual(
    new Date('2026-03-08T09:00:00Z'),
  );
});
