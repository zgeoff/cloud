import { expect, test } from 'bun:test';
import { findJSONField } from '../find-json-field.ts';
import { nixieAPICheckCalls } from './nixie-api-check-calls.ts';
import { nixieProcedureKinds } from './nixie-procedure-kinds.ts';

test('it calls only procedures that read nixie, never one that writes', () => {
  const calls = nixieAPICheckCalls.map((call) => ({
    procedure: call.procedure,
    kind: findJSONField(nixieProcedureKinds, call.procedure),
  }));

  expect(calls).toStrictEqual([
    { procedure: 'sessions/list', kind: 'read' },
    { procedure: 'conversation/read', kind: 'read' },
  ]);
});
