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
