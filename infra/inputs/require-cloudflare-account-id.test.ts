import { expect, test } from 'bun:test';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';

test('it returns the account ID when it is set', () => {
  expect(
    requireCloudflareAccountID({ CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef' }),
  ).toBe('0123456789abcdef0123456789abcdef');
});

test('it throws when the account ID is unset', () => {
  expect(() => requireCloudflareAccountID({})).toThrowWithMessage(
    Error,
    'CLOUDFLARE_ACCOUNT_ID is unset; run through `op run --env-file=../.env`',
  );
});

test.each([
  ['empty', ''],
  ['only whitespace', ' \n'],
])('it throws when the account ID is %s', (_kind, accountID) => {
  expect(() => requireCloudflareAccountID({ CLOUDFLARE_ACCOUNT_ID: accountID })).toThrowWithMessage(
    Error,
    'CLOUDFLARE_ACCOUNT_ID is blank; run through `op run --env-file=../.env`',
  );
});
