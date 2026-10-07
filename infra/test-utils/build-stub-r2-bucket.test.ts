import { expect, test } from 'bun:test';
import { buildStubR2Bucket } from './build-stub-r2-bucket.ts';

test('it reads a key never put as null', () => {
  expect(buildStubR2Bucket().get('state:atc')).resolves.toBeNull();
});

test('it reads back the text of a value it was given', async () => {
  const bucket = buildStubR2Bucket({ 'state:atc': 'up' });

  const stored = await bucket.get('state:atc');

  if (stored === null) {
    throw new Error('expected the stored object');
  }

  expect(stored.text()).resolves.toBe('up');
});

test('it replaces the value of a key on put', async () => {
  const bucket = buildStubR2Bucket({ 'state:atc': 'up' });

  await bucket.put('state:atc', 'tunnel-down');

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'tunnel-down' });
});
