import { expect, test } from 'bun:test';
import { findReleaseRecord } from './find-release-record.ts';

test.each(['atc', 'imp', 'nixie', 'auto-mode'])(
  'it finds the %s record from its release check branch',
  (name) => {
    expect(findReleaseRecord(`release-check/${name}`)?.name).toBe(name);
  },
);

test('it finds no record for another release check branch', () => {
  expect(findReleaseRecord('release-check/renovate')).toBeUndefined();
});

test('it finds no record for a bare dependency name', () => {
  expect(findReleaseRecord('atc')).toBeUndefined();
});
