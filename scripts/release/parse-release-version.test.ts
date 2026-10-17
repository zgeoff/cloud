import { expect, test } from 'bun:test';
import { parseReleaseVersion } from './parse-release-version.ts';

test('it parses each part as a number', () => {
  expect(parseReleaseVersion('4.10.0')).toStrictEqual({ major: 4, minor: 10, patch: 0 });
});

test.each(['v4.10.0', '4.10', '4.10.0-rc.1', '4.10.0 ', 'x.y.z', ''])(
  'it gives no version for %p',
  (text) => {
    expect(parseReleaseVersion(text)).toBeUndefined();
  },
);
