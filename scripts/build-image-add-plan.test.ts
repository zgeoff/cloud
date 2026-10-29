import { expect, test } from 'bun:test';
import { buildImageAddPlan } from './build-image-add-plan.ts';

test('it adds an image that impd does not hold', () => {
  expect(
    buildImageAddPlan(
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      ],
      [
        {
          name: 'nixie-fetch-1234567890ab',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
          digest: 'sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        },
      ],
    ),
  ).toStrictEqual({
    adds: [
      {
        name: 'nixie-fetch-77aa88bb99cc',
        ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      },
    ],
    held: [],
    conflicts: [],
  });
});

test('it skips an image that impd holds at the manifest digest', () => {
  expect(
    buildImageAddPlan(
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      ],
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      ],
    ),
  ).toStrictEqual({ adds: [], held: ['nixie-fetch-77aa88bb99cc'], conflicts: [] });
});

test('it skips an image whose held ref pins the manifest digest while impd records another', () => {
  expect(
    buildImageAddPlan(
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      ],
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
        },
      ],
    ),
  ).toStrictEqual({ adds: [], held: ['nixie-fetch-77aa88bb99cc'], conflicts: [] });
});

test('it refuses an image that impd holds under the same name at another digest', () => {
  expect(
    buildImageAddPlan(
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
          digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      ],
      [
        {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
          digest: 'sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
        },
      ],
    ),
  ).toStrictEqual({
    adds: [],
    held: [],
    conflicts: [
      'impd holds the image nixie-fetch-77aa88bb99cc at sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f from ghcr.io/zgeoff/nixie-fetch@sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f, not sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
    ],
  });
});
