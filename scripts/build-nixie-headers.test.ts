import { expect, test } from 'bun:test';
import { buildNixieHeaders } from './build-nixie-headers.ts';

test('it sends the client header and the session as a bearer token', () => {
  expect(buildNixieHeaders('5f0c2a7e-token')).toStrictEqual({
    'content-type': 'application/json',
    'x-nixie-client': 'deploy-check',
    authorization: 'Bearer 5f0c2a7e-token',
  });
});

test('it sends no authorization before the check has a session', () => {
  expect(buildNixieHeaders(null)).toStrictEqual({
    'content-type': 'application/json',
    'x-nixie-client': 'deploy-check',
  });
});
