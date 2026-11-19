import { expect, test } from 'bun:test';
import invariant from 'tiny-invariant';
import { buildStubR2Bucket } from './build-stub-r2-bucket.ts';

test('it reads a key never put as null', () => {
  expect(buildStubR2Bucket().get('state:atc')).resolves.toBeNull();
});

test('it reads a stored key as an R2 object body with the metadata of a single-part upload', () => {
  expect(buildStubR2Bucket({ 'state:atc': 'up' }).get('state:atc')).resolves.toStrictEqual({
    key: 'state:atc',
    version: expect.toSatisfy((value: string) => /^[0-9a-f]{32}$/u.test(value)),
    size: 2,
    etag: '46c48bec0d282018b9d167eef7711b2c',
    httpEtag: '"46c48bec0d282018b9d167eef7711b2c"',
    checksums: {
      md5: expect.toSatisfy((value: unknown) => value instanceof ArrayBuffer),
      toJSON: expect.toBeFunction(),
    },
    uploaded: expect.toBeValidDate(),
    httpMetadata: {},
    customMetadata: {},
    storageClass: 'Standard',
    writeHttpMetadata: expect.toBeFunction(),
    bodyUsed: false,
    arrayBuffer: expect.toBeFunction(),
    bytes: expect.toBeFunction(),
    text: expect.toBeFunction(),
  });
});

test('it reads back the text of a value it was given', async () => {
  const stored = await buildStubR2Bucket({ 'state:atc': 'up' }).get('state:atc');

  expect(stored?.text()).resolves.toBe('up');
});

test('it marks the body used once it is read', async () => {
  const stored = await buildStubR2Bucket({ 'state:atc': 'up' }).get('state:atc');

  invariant(stored !== null, 'expected the stored object');

  await stored.text();

  expect(stored.bodyUsed).toBeTrue();
});

test('it reports the MD5 checksum as hex', async () => {
  const stored = await buildStubR2Bucket({ 'state:atc': 'up' }).get('state:atc');

  expect(stored?.checksums.toJSON()).toStrictEqual({ md5: '46c48bec0d282018b9d167eef7711b2c' });
});

test('it replaces the value of a key on put', async () => {
  const bucket = buildStubR2Bucket({ 'state:atc': 'up' });

  await bucket.put('state:atc', 'tunnel-down');

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'tunnel-down' });
});

test('it resolves a put with the R2 object it stored', () => {
  expect(buildStubR2Bucket().put('state:atc', 'tunnel-down')).resolves.toStrictEqual({
    key: 'state:atc',
    version: expect.toSatisfy((value: string) => /^[0-9a-f]{32}$/u.test(value)),
    size: 11,
    etag: 'e4eaaf55afff2d80da80b59cf9be2f77',
    httpEtag: '"e4eaaf55afff2d80da80b59cf9be2f77"',
    checksums: {
      md5: expect.toSatisfy((value: unknown) => value instanceof ArrayBuffer),
      toJSON: expect.toBeFunction(),
    },
    uploaded: expect.toBeValidDate(),
    httpMetadata: {},
    customMetadata: {},
    storageClass: 'Standard',
    writeHttpMetadata: expect.toBeFunction(),
  });
});

test('it gives each put a new version', async () => {
  const bucket = buildStubR2Bucket();

  const first = await bucket.put('state:atc', 'up');
  const second = await bucket.put('state:atc', 'up');

  invariant(first !== null && second !== null, 'expected both stored objects');

  expect(second.version).not.toBe(first.version);
});
