import { expect, test } from 'bun:test';
import { parseNixieSandboxManifest } from './parse-nixie-sandbox-manifest.ts';

test('it reads each image of the manifest with the digest its ref pins', () => {
  expect(
    parseNixieSandboxManifest(
      JSON.stringify({
        conversation: {
          name: 'nixie-conversation-5c0ffee0aa11',
          ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
        },
        fetch: {
          name: 'nixie-fetch-77aa88bb99cc',
          ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        },
      }),
    ),
  ).toStrictEqual({
    ok: true,
    images: [
      {
        name: 'nixie-conversation-5c0ffee0aa11',
        ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
        digest: 'sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
      },
      {
        name: 'nixie-fetch-77aa88bb99cc',
        ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      },
    ],
  });
});

test("it refuses a ref outside nixie's registry path", () => {
  expect(
    parseNixieSandboxManifest(
      JSON.stringify({
        conversation: {
          name: 'nixie-conversation-5c0ffee0aa11',
          ref: 'ghcr.io/someone/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
        },
      }),
    ),
  ).toStrictEqual({
    ok: false,
    error:
      "nixie's sandbox manifest: ✖ Invalid string: must match pattern /^ghcr\\.io\\/zgeoff\\/nixie-[a-z0-9-]+@(?<digest>sha256:[0-9a-f]{64})$/u\n  → at conversation.ref",
  });
});

test('it refuses a ref that a tag names rather than a digest', () => {
  expect(
    parseNixieSandboxManifest(
      JSON.stringify({
        conversation: {
          name: 'nixie-conversation-5c0ffee0aa11',
          ref: 'ghcr.io/zgeoff/nixie-conversation:0.42.0',
        },
      }),
    ),
  ).toStrictEqual({
    ok: false,
    error:
      "nixie's sandbox manifest: ✖ Invalid string: must match pattern /^ghcr\\.io\\/zgeoff\\/nixie-[a-z0-9-]+@(?<digest>sha256:[0-9a-f]{64})$/u\n  → at conversation.ref",
  });
});

test("it refuses a name without nixie's prefix", () => {
  expect(
    parseNixieSandboxManifest(
      JSON.stringify({
        conversation: {
          name: 'conversation-5c0ffee0aa11',
          ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
        },
      }),
    ),
  ).toStrictEqual({
    ok: false,
    error:
      "nixie's sandbox manifest: ✖ Invalid string: must match pattern /^nixie-[a-z0-9-]+$/u\n  → at conversation.name",
  });
});

test('it refuses a manifest that lists no image', () => {
  expect(parseNixieSandboxManifest('{}')).toStrictEqual({
    ok: false,
    error: "nixie's sandbox manifest lists no image",
  });
});

test('it refuses output that is not JSON', () => {
  expect(parseNixieSandboxManifest('error: no manifest\n')).toStrictEqual({
    ok: false,
    error: 'nixie printed a sandbox manifest that is not JSON',
  });
});
