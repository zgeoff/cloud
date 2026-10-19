import { expect, test } from 'bun:test';
import { isSafeFilename } from './is-safe-filename.ts';

test.each([
  ['screenshot.png'],
  ['plan v2 (final).pdf'],
  ['naïve.txt'],
  ['.env.example'],
  ['a'.repeat(255)],
])('it accepts %p', (filename) => {
  expect(isSafeFilename(filename)).toBeTrue();
});

test.each([
  ['an empty name', ''],
  ['.', '.'],
  ['..', '..'],
  ['a slash', 'a/b.png'],
  ['a backslash', String.raw`a\b.png`],
  ['a newline', 'a\nb.png'],
  ['a NUL', 'a\u0000b.png'],
  ['a DEL', 'a\u007Fb.png'],
  ['256 bytes', 'a'.repeat(256)],
  ['256 bytes of UTF-8 in 128 characters', 'é'.repeat(128)],
])('it refuses a name with %s', (_label, filename) => {
  expect(isSafeFilename(filename)).toBeFalse();
});
