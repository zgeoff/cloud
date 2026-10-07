import { expect, test } from 'bun:test';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';

test('it returns the account ID when it is set', () => {
  expect(requireCloudflareAccountID('0123456789abcdef0123456789abcdef')).toBe(
    '0123456789abcdef0123456789abcdef',
  );
});

test('it throws when the account ID is unset', () => {
  expect(() => requireCloudflareAccountID(undefined)).toThrowWithMessage(
    Error,
    'CLOUDFLARE_ACCOUNT_ID is unset; run through `op run --env-file=../.env`',
  );
});
