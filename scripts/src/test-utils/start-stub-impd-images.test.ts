import { expect, test } from 'bun:test';
import { createImpClient } from '@impz/client';
import { server } from './server.ts';
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

test.each([
  ['images/list', 'no authorization header', {}],
  ['images/list', 'another token', { authorization: 'Bearer another-token' }],
  [
    'images/list',
    'the token under another scheme',
    { authorization: 'Basic impd-token-for-tests' },
  ],
  ['images/list', 'the token with a suffix', { authorization: 'Bearer impd-token-for-tests-x' }],
  ['images/list', 'a prefix of the token', { authorization: 'Bearer impd-token' }],
  ['images/add', 'no authorization header', {}],
  ['images/add', 'another token', { authorization: 'Bearer another-token' }],
  ['images/add', 'the token under another scheme', { authorization: 'Basic impd-token-for-tests' }],
  ['images/add', 'the token with a suffix', { authorization: 'Bearer impd-token-for-tests-x' }],
  ['images/add', 'a prefix of the token', { authorization: 'Bearer impd-token' }],
])(
  'it refuses a call to %s with %s as unauthorized and records nothing',
  async (path, _label, headers) => {
    const impd = startStubImpdImages({
      url: 'https://impd.test',
      token: 'impd-token-for-tests',
      images: [],
    });

    server.use(...impd.handlers);

    const response = await fetch(`https://impd.test/rpc/${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify({
        json: {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
        meta: [],
      }),
    });

    expect(response.status).toBe(401);
    expect(impd.calls).toStrictEqual([]);
    expect(impd.images).toStrictEqual([]);
  },
);

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
