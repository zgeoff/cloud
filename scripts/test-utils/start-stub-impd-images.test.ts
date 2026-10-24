import { expect, test } from 'bun:test';
import { createImpClient } from '@impz/client';
import { server } from '../mocks/node.ts';
import { startStubImpdImages } from './start-stub-impd-images.ts';

test("it lists its images to imp's typed client, with each record's created time as a Date", async () => {
  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'impd-token-for-tests',
    images: [
      {
        name: 'nixie-fetch-77aa88bb99cc',
        ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      },
    ],
  });

  server.use(...impd.handlers);

  const client = createImpClient({ url: 'https://impd.test', token: 'impd-token-for-tests' });

  const listed = await client.images.list();

  expect(listed).toStrictEqual([
    {
      id: 'image-nixie-fetch-77aa88bb99cc',
      name: 'nixie-fetch-77aa88bb99cc',
      ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      source: 'oci',
      createdAt: new Date('2026-10-01T00:00:00.000Z'),
      sizeBytes: 1_048_576,
      pinned: false,
    },
  ]);
});

test('it holds an added image and records the add', async () => {
  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'impd-token-for-tests',
    images: [],
  });

  server.use(...impd.handlers);

  const client = createImpClient({ url: 'https://impd.test', token: 'impd-token-for-tests' });

  await client.images.add({
    name: 'nixie-fetch-77aa88bb99cc',
    ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
  });

  expect(impd.images).toStrictEqual([
    {
      name: 'nixie-fetch-77aa88bb99cc',
      ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
    },
  ]);

  expect(impd.calls).toStrictEqual([
    'images.add nixie-fetch-77aa88bb99cc ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
  ]);
});

test('it refuses an add of a refused ref with a FORBIDDEN error that the client throws', () => {
  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'impd-token-for-tests',
    images: [],
    refusedRefs: [
      'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
    ],
  });

  server.use(...impd.handlers);

  const client = createImpClient({ url: 'https://impd.test', token: 'impd-token-for-tests' });

  expect(
    client.images.add({
      name: 'nixie-fetch-77aa88bb99cc',
      ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
    }),
  ).rejects.toMatchObject({
    code: 'FORBIDDEN',
    message: 'token nixie may add only images whose ref starts with ghcr.io/zgeoff/nixie-',
  });
});

test('it refuses a call with another token as unauthorized', () => {
  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'impd-token-for-tests',
    images: [],
  });

  server.use(...impd.handlers);

  const client = createImpClient({ url: 'https://impd.test', token: 'another-token' });

  expect(client.images.list()).rejects.toMatchObject({ code: 'UNAUTHORIZED' });
});
