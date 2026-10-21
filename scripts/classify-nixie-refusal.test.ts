import { expect, test } from 'bun:test';
import { classifyNixieRefusal } from './classify-nixie-refusal.ts';

test("it passes nixie's own 401 UNAUTHORIZED refusal", () => {
  expect(
    classifyNixieRefusal({
      kind: 'answered',
      status: 401,
      answer: { ok: false, code: 'UNAUTHORIZED', isDefined: true },
    }),
  ).toBeNull();
});

test.each([
  [
    'an output to a call without a session',
    200,
    { ok: true, output: { sessions: [] } },
    'answered 200 with an output to a call without a session',
  ],
  [
    "a proxy's own 401, which oRPC reads as UNAUTHORIZED",
    401,
    { ok: false, code: 'UNAUTHORIZED', isDefined: false },
    "answered 401 with no error that nixie's contract defines, not 401 UNAUTHORIZED",
  ],
  [
    'a body that is no RPC error',
    502,
    { ok: false, code: null, isDefined: false },
    "answered 502 with no error that nixie's contract defines, not 401 UNAUTHORIZED",
  ],
  [
    'another error that nixie defines',
    404,
    { ok: false, code: 'THREAD_NOT_FOUND', isDefined: true },
    'answered 404 THREAD_NOT_FOUND, not 401 UNAUTHORIZED',
  ],
  [
    'UNAUTHORIZED under another status',
    403,
    { ok: false, code: 'UNAUTHORIZED', isDefined: true },
    'answered 403 UNAUTHORIZED, not 401 UNAUTHORIZED',
  ],
  [
    'a defined 401 with no code',
    401,
    { ok: false, code: null, isDefined: true },
    'answered 401 with no error code, not 401 UNAUTHORIZED',
  ],
] as const)('it refuses %s', (_label, status, answer, expected) => {
  expect(classifyNixieRefusal({ kind: 'answered', status, answer })).toBe(expected);
});

test('it fails a call that reached no server, with the error', () => {
  expect(classifyNixieRefusal({ kind: 'unreached', error: 'TypeError: Unable to connect' })).toBe(
    'failed: TypeError: Unable to connect',
  );
});

test('it fails an answer whose body broke off', () => {
  expect(classifyNixieRefusal({ kind: 'broken', status: 401 })).toBe(
    'answered 401 with a body that broke off',
  );
});
