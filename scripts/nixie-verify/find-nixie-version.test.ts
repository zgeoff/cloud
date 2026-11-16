import { expect, test } from 'bun:test';
import { findNixieVersion } from './find-nixie-version.ts';

test('it finds the release of the pinned nixie image', () => {
  const text = [
    'config:',
    '  geoff-cloud:nixie:',
    '    image: ghcr.io/zgeoff/nixie:0.74.0@sha256:456a48906e5ae0c444d84860057ad59e52a90ba485eceb64ea9437474372db6f',
    '    webImage: ghcr.io/zgeoff/nixie-web:0.74.0@sha256:dff6aeb50936b80cc0e174e3078958c56087aed6e0c16c1df3c22a8555a50a50',
    '',
  ].join('\n');

  expect(findNixieVersion(text)).toBe('0.74.0');
});

test.each([
  ['an image with no digest', '    image: ghcr.io/zgeoff/nixie:0.74.0'],
  [
    'an image from another repository',
    '    image: ghcr.io/zgeoff/nixie-web:0.74.0@sha256:dff6aeb50936b80cc0e174e3078958c56087aed6e0c16c1df3c22a8555a50a50',
  ],
  ['no image', '    hostname: chat.example.test'],
])('it finds no release in a stack config with %s', (_title, line) => {
  expect(findNixieVersion(['config:', '  geoff-cloud:nixie:', line, ''].join('\n'))).toBeNull();
});
