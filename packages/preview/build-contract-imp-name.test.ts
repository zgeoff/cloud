import { expect, test } from 'bun:test';
import { buildContractImpName } from './build-contract-imp-name.ts';
import { buildImpName } from './build-imp-name.ts';

test('it names the imp after a hash of the repository and the head commit, inside the token prefix', () => {
  expect(
    buildContractImpName('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).toMatch(/^pv-sdk-[\da-f]{16}$/u);
});

test('it gives two head commits of one repository two names', () => {
  expect(
    buildContractImpName('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).not.toBe(buildContractImpName('acme/greenhouse', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'));
});

test('it gives one head commit in two repositories two names', () => {
  expect(
    buildContractImpName('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).not.toBe(buildContractImpName('acme/orchard', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
});

test("it never gives a run's imp the name of a preview's imp", () => {
  expect(buildImpName('acme/greenhouse', 17)).not.toStartWith('pv-sdk-');
});

test('it keeps the name within impd limit of 31 characters', () => {
  expect(
    buildContractImpName('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).toMatch(/^[a-z][\da-z-]{0,30}$/u);
});
