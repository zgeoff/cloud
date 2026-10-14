import { expect, test } from 'bun:test';
import { parseTeamName } from './parse-team-name.ts';

test('it takes the team name from the auth domain', () => {
  expect(parseTeamName('geoff-cloud.cloudflareaccess.com')).toBe('geoff-cloud');
});

test.each([
  ['a custom domain', 'access.geoff.cloud'],
  ['a nested label', 'a.b.cloudflareaccess.com'],
  ['the bare suffix', '.cloudflareaccess.com'],
])('it refuses %s', (_label: string, authDomain: string) => {
  expect(() => parseTeamName(authDomain)).toThrowWithMessage(
    Error,
    `the Zero Trust auth domain ${authDomain} is not <team>.cloudflareaccess.com, so cloudflared cannot check Access tokens`,
  );
});
