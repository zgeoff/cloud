import { expect, test } from 'bun:test';
import { buildImpName } from './build-imp-name.ts';

test('it names the imp after a hash of the repository and the pull request number', () => {
  expect(buildImpName('acme/greenhouse', 17)).toMatch(/^pv-[\da-f]{8}-17$/u);
});

test('it gives one pull request number in two repositories two names', () => {
  expect(buildImpName('acme/greenhouse', 17)).not.toBe(buildImpName('acme/orchard', 17));
});

test('it gives one repository the same name whatever its case', () => {
  expect(buildImpName('Acme/Greenhouse', 17)).toBe(buildImpName('acme/greenhouse', 17));
});

test('it keeps the name within impd limit of 31 characters for the largest pull request number', () => {
  expect(buildImpName('acme/greenhouse', Number.MAX_SAFE_INTEGER)).toMatch(
    /^[a-z][\da-z-]{0,30}$/u,
  );
});
