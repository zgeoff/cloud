import { expect, test } from 'bun:test';
import { collectAssetSums } from './collect-asset-sums.ts';

test('it collects the sum of each asset with a sha256 digest', () => {
  expect(
    collectAssetSums([
      { name: 'one.tar.gz', digest: `sha256:${'a'.repeat(64)}` },
      { name: 'two.tar.gz', digest: `sha256:${'b'.repeat(64)}` },
    ]),
  ).toStrictEqual({ 'one.tar.gz': 'a'.repeat(64), 'two.tar.gz': 'b'.repeat(64) });
});

test.each([
  ['an absent digest', { name: 'one.zip' }],
  ['a null digest', { name: 'one.zip', digest: null }],
  ['another algorithm', { name: 'one.zip', digest: `sha512:${'a'.repeat(64)}` }],
  ['a short sum', { name: 'one.zip', digest: `sha256:${'a'.repeat(63)}` }],
  ['an upper-case sum', { name: 'one.zip', digest: `sha256:${'A'.repeat(64)}` }],
  ['no name', { digest: `sha256:${'a'.repeat(64)}` }],
])('it leaves out an asset with %s', (_title, asset) => {
  expect(collectAssetSums([asset])).toStrictEqual({});
});

test('it collects nothing from a value that is no list', () => {
  expect(collectAssetSums({ message: 'Not Found' })).toStrictEqual({});
});
