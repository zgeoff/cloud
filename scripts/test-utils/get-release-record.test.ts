import { expect, test } from 'bun:test';
import { getReleaseRecord } from './get-release-record.ts';

test('it gets the record of that name', () => {
  expect(getReleaseRecord('nixie').repo).toBe('zgeoff/nixie');
});

test('it throws for a name the registry lacks', () => {
  expect(() => getReleaseRecord('renovate')).toThrowWithMessage(
    Error,
    'the release registry has no renovate record',
  );
});
