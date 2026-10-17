import { expect, test } from 'bun:test';
import { findNewestRelease } from './find-newest-release.ts';

test('it takes the highest version among the tags of the dependency own form', () => {
  expect(
    findNewestRelease(
      [
        '@zgeoff/atc@4.9.0',
        '@zgeoff/atc@4.10.0',
        '@zgeoff/atc-sdk@9.0.0',
        'v5.0.0',
        '@zgeoff/atc@4.10.0-rc.1',
      ],
      '@zgeoff/atc@',
    ),
  ).toBe('4.10.0');
});

test('it reads tags in any order', () => {
  expect(findNewestRelease(['v0.31.0', 'v0.32.1', 'v0.32.0'], 'v')).toBe('0.32.1');
});

test('it finds no release among tags of another form', () => {
  expect(findNewestRelease(['auto-mode-2.0.0', 'v2.0.0'], 'auto-mode-v')).toBeUndefined();
});

test('it finds no release without tags', () => {
  expect(findNewestRelease([], 'v')).toBeUndefined();
});
