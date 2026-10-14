import { expect, test } from 'bun:test';
import { requireGHCRPullCredential } from './require-ghcr-pull-credential.ts';

test('it returns the login and the token as given', () => {
  expect(
    requireGHCRPullCredential({
      GHCR_PULL_USERNAME: 'octo-puller',
      GHCR_PULL_TOKEN: `ghp_${'t'.repeat(36)}`,
    }),
  ).toStrictEqual({ username: 'octo-puller', token: `ghp_${'t'.repeat(36)}` });
});

test.each([
  ['unset', {}, 'GHCR_PULL_USERNAME is unset'],
  ['blank', { GHCR_PULL_USERNAME: ' ' }, 'GHCR_PULL_USERNAME is blank'],
  ['unset', { GHCR_PULL_USERNAME: 'octo-puller' }, 'GHCR_PULL_TOKEN is unset'],
  [
    'blank',
    { GHCR_PULL_USERNAME: 'octo-puller', GHCR_PULL_TOKEN: '\n' },
    'GHCR_PULL_TOKEN is blank',
  ],
])('it throws, naming the variable, when one is %s', (_kind, env, start) => {
  expect(() => requireGHCRPullCredential(env)).toThrowWithMessage(
    Error,
    `${start}; the atc gateway's images are private, so .env must reference op://cloud/ghcr-pull`,
  );
});

test.each(['octo puller', 'octo:puller', 'octo-puller\n'])(
  'it refuses the login %j',
  (username) => {
    expect(() =>
      requireGHCRPullCredential({
        GHCR_PULL_USERNAME: username,
        GHCR_PULL_TOKEN: `ghp_${'t'.repeat(36)}`,
      }),
    ).toThrowWithMessage(
      Error,
      'GHCR_PULL_USERNAME must be the one GitHub login, with no whitespace or colon',
    );
  },
);

test.each([`ghp_${'t'.repeat(36)}\n`, `ghp_${'t'.repeat(18)} ${'t'.repeat(18)}`])(
  'it refuses a token with whitespace, without printing it',
  (token) => {
    expect(() =>
      requireGHCRPullCredential({ GHCR_PULL_USERNAME: 'octo-puller', GHCR_PULL_TOKEN: token }),
    ).toThrowWithMessage(Error, 'GHCR_PULL_TOKEN must be the one token, with no whitespace');
  },
);
