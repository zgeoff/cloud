import { expect, test } from 'bun:test';
import { parseBoxxyNoticeSession } from './parse-boxxy-notice-session.ts';

test('it returns a gateway ID as given', () => {
  expect(parseBoxxyNoticeSession('owner-pc.0a1b2c3d.11111111-2222-3333-4444-555555555555')).toBe(
    'owner-pc.0a1b2c3d.11111111-2222-3333-4444-555555555555',
  );
});

test.each([
  ['a bare session ID', '11111111-2222-3333-4444-555555555555'],
  ['a session name', 'owner-session'],
  ['two parts', 'owner-pc.11111111-2222-3333-4444-555555555555'],
  ['empty', ''],
])('it refuses a notice session that is %s, without quoting it', (_name, session) => {
  expect(() => parseBoxxyNoticeSession(session)).toThrowWithMessage(
    Error,
    'stack config "boxxyNoticeSession" must be the notice session\'s gateway ID, <daemon>.<incarnation>.<id>, as atc_sessions_list prints it through the gateway',
  );
});
