import { expect, test } from 'bun:test';
import { isNewerVersion } from './is-newer-version.ts';

test.each([
  {
    label: 'a later major',
    candidate: { major: 2, minor: 0, patch: 0 },
    base: { major: 1, minor: 9, patch: 9 },
    newer: true,
  },
  {
    label: 'a later minor',
    candidate: { major: 1, minor: 10, patch: 0 },
    base: { major: 1, minor: 9, patch: 9 },
    newer: true,
  },
  {
    label: 'a later patch',
    candidate: { major: 1, minor: 9, patch: 10 },
    base: { major: 1, minor: 9, patch: 9 },
    newer: true,
  },
  {
    label: 'the same version',
    candidate: { major: 1, minor: 9, patch: 9 },
    base: { major: 1, minor: 9, patch: 9 },
    newer: false,
  },
  {
    label: 'an earlier minor',
    candidate: { major: 1, minor: 8, patch: 20 },
    base: { major: 1, minor: 9, patch: 0 },
    newer: false,
  },
  {
    label: 'an earlier major',
    candidate: { major: 0, minor: 99, patch: 0 },
    base: { major: 1, minor: 0, patch: 0 },
    newer: false,
  },
])('it compares $label as numbers', (row) => {
  expect(isNewerVersion(row.candidate, row.base)).toBe(row.newer);
});
