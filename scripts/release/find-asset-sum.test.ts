import { expect, test } from 'bun:test';
import { findAssetSum } from './find-asset-sum.ts';

test('it finds the sum of a text-mode line', () => {
  expect(
    findAssetSum(
      `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
      'atc-linux-x64',
    ),
  ).toBe('4'.repeat(64));
});

test('it finds the sum of a binary-mode line', () => {
  expect(findAssetSum(`${'6'.repeat(64)} *atc-gateway-linux-x64\n`, 'atc-gateway-linux-x64')).toBe(
    '6'.repeat(64),
  );
});

test('it refuses sums without a line for the asset', () => {
  expect(findAssetSum(`${'5'.repeat(64)}  atc-gateway-linux-x64\n`, 'atc-linux-x64')).toStrictEqual(
    new Error('SHA256SUMS has 0 atc-linux-x64 lines, want 1'),
  );
});

test('it refuses sums with two lines for the asset', () => {
  expect(
    findAssetSum(
      `${'4'.repeat(64)}  atc-linux-x64\n${'7'.repeat(64)}  atc-linux-x64\n`,
      'atc-linux-x64',
    ),
  ).toStrictEqual(new Error('SHA256SUMS has 2 atc-linux-x64 lines, want 1'));
});

test('it refuses a line for the asset that holds no sha256', () => {
  expect(findAssetSum('not-a-sum  atc-linux-x64\n', 'atc-linux-x64')).toStrictEqual(
    new Error("SHA256SUMS's atc-linux-x64 line holds no sha256 sum"),
  );
});

test('it does not take a line for an asset whose name ends with the asset name', () => {
  expect(findAssetSum(`${'8'.repeat(64)}  old-atc-linux-x64\n`, 'atc-linux-x64')).toStrictEqual(
    new Error('SHA256SUMS has 0 atc-linux-x64 lines, want 1'),
  );
});
