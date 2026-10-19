import { expect, test } from 'bun:test';
import { requirePinnedImage } from './require-pinned-image.ts';

test('it accepts an image named by tag and digest', () => {
  expect(() => {
    requirePinnedImage(
      'files.image',
      'ghcr.io/zgeoff/cloud-files:abc123@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
    );
  }).not.toThrow();
});

test.each([
  ['an unset value', undefined],
  ['a tag alone', 'ghcr.io/zgeoff/cloud-files:abc123'],
  [
    'a digest alone',
    'ghcr.io/zgeoff/cloud-files@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
  ],
])('it refuses %s, naming the key', (_label, image) => {
  expect(() => {
    requirePinnedImage('files.image', image);
  }).toThrowWithMessage(Error, 'stack config "files.image" must name an image by tag and digest');
});
