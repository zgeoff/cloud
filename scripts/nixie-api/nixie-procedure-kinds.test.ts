import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { collectNixieActionProcedures } from './collect-nixie-action-procedures.ts';
import { nixieProcedureKinds } from './nixie-procedure-kinds.ts';

test('it counts as a write every procedure of the vendored contract that takes a client action ID', async () => {
  const document: unknown = await Bun.file(join(import.meta.dir, 'openapi.json')).json();

  const kinds = collectNixieActionProcedures(document).map((procedure) =>
    Reflect.get(nixieProcedureKinds, procedure),
  );

  expect(kinds).not.toBeEmpty();
  expect(kinds).toSatisfyAll((kind: unknown) => kind === 'write');
});
