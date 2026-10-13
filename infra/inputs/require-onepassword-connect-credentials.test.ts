import { expect, test } from 'bun:test';
import { requireOnePasswordConnectCredentials } from './require-onepassword-connect-credentials.ts';

test('it returns a JSON object unchanged', () => {
  expect(requireOnePasswordConnectCredentials({ ONEPASSWORD_CONNECT_CREDENTIALS: '{"a":1}' })).toBe(
    '{"a":1}',
  );
});

test('it returns an empty JSON object', () => {
  expect(requireOnePasswordConnectCredentials({ ONEPASSWORD_CONNECT_CREDENTIALS: '{}' })).toBe(
    '{}',
  );
});

test('it returns the value untrimmed', () => {
  expect(
    requireOnePasswordConnectCredentials({ ONEPASSWORD_CONNECT_CREDENTIALS: ' {"a":1}\n' }),
  ).toBe(' {"a":1}\n');
});

test.each([
  ['missing', {}],
  ['empty', { ONEPASSWORD_CONNECT_CREDENTIALS: '' }],
  ['blank', { ONEPASSWORD_CONNECT_CREDENTIALS: ' \n' }],
])('it throws when the value is %s', (_kind, env) => {
  expect(() => requireOnePasswordConnectCredentials(env)).toThrowWithMessage(
    Error,
    'cluster is managed, but ONEPASSWORD_CONNECT_CREDENTIALS is empty; run through `op run --env-file=../.env`',
  );
});

// the full message carries no part of the value, so an exact match also proves it is not echoed
test.each(['not-json-secret', '[1]', '"s"', 'null', '3'])(
  'it throws, without echoing it, when the value %p is not a JSON object',
  (value) => {
    expect(() =>
      requireOnePasswordConnectCredentials({ ONEPASSWORD_CONNECT_CREDENTIALS: value }),
    ).toThrowWithMessage(Error, 'ONEPASSWORD_CONNECT_CREDENTIALS is not a JSON object');
  },
);
