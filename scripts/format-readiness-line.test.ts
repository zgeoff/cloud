import { expect, test } from 'bun:test';
import { formatReadinessLine } from './format-readiness-line.ts';

test.each([
  ['ok', 'ok       exists: namespace atc\n'],
  ['missing', 'missing  exists: namespace atc\n'],
  ['FAIL', 'FAIL     exists: namespace atc\n'],
] as const)('it pads the %s status to eight columns', (status, line) => {
  expect(formatReadinessLine({ status, text: 'exists: namespace atc' })).toBe(line);
});
