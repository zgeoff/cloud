import { expect, test } from 'bun:test';
import { findFetchImage } from './find-fetch-image.ts';

test('it names the fetch image after the first 12 hex of its digest', () => {
  expect(
    findFetchImage(
      '{"conversation":"ghcr.io/zgeoff/nixie-conversation:0.3.0@sha256:1111111111111111111111111111111111111111111111111111111111111111","fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0@sha256:9c4e2a71b0d35f68e1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708"}',
    ),
  ).toBe('nixie-fetch-9c4e2a71b0d3');
});

test.each([
  ['a manifest with no fetch image', '{"conversation":"ghcr.io/zgeoff/nixie-conversation:0.3.0"}'],
  ['a fetch image named by tag alone', '{"fetch":"ghcr.io/zgeoff/nixie-fetch:0.3.0"}'],
  ['text that is not JSON', 'cat: /app/sandbox-manifest.json: No such file or directory'],
])('it finds no image in %s', (_label: string, text: string) => {
  expect(findFetchImage(text)).toBeUndefined();
});
