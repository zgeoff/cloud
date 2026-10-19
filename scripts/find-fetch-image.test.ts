import { expect, test } from 'bun:test';
import { findFetchImage } from './find-fetch-image.ts';

test('it finds the name nixie gives the fetch image', () => {
  expect(
    findFetchImage(
      '{"conversation":{"name":"nixie-conversation-111111111111","ref":"ghcr.io/zgeoff/nixie-conversation:0.3.0@sha256:1111111111111111111111111111111111111111111111111111111111111111"},"fetch":{"name":"nixie-fetch-9c4e2a71b0d3","ref":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}}',
    ),
  ).toBe('nixie-fetch-9c4e2a71b0d3');
});

test.each([
  [
    'a manifest with no fetch image',
    '{"conversation":{"name":"nixie-conversation-111111111111","ref":"ghcr.io/zgeoff/nixie-conversation:0.3.0"}}',
  ],
  [
    'the manifest file nixie reads, which names no image',
    '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
  ],
  ['a name outside the fetch image names', '{"fetch":{"name":"base","ref":"ghcr.io/x/base"}}'],
  ['text that is not JSON', 'nixie has no command sandbox-manifest; it takes serve, health'],
])('it finds no image in %s', (_label: string, text: string) => {
  expect(findFetchImage(text)).toBeUndefined();
});
