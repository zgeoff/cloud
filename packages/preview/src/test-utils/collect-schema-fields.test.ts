import { expect, test } from 'bun:test';
import { z } from 'zod';
import { collectSchemaFields } from './collect-schema-fields.ts';

test('it lists the nested fields of a schema with their types, sorted', () => {
  const listen = z.strictObject({ port: z.int(), hostname: z.string() });
  const config = z.strictObject({ store: z.string(), listen });

  expect(collectSchemaFields(z.toJSONSchema(config))).toStrictEqual([
    'listen.hostname: string',
    'listen.port: integer',
    'store: string',
  ]);
});

test('it marks an optional field and lists the values of a record under a star', () => {
  const tokens = z.int().optional();
  const limits = z.strictObject({ tokens });
  const route = z.strictObject({ model: z.string() });
  const routes = z.record(z.string(), route);
  const config = z.strictObject({ limits, routes });

  expect(collectSchemaFields(z.toJSONSchema(config))).toStrictEqual([
    'limits.tokens?: integer',
    'routes.*.model: string',
  ]);
});

test('it lists nothing for a value that is no schema', () => {
  expect(collectSchemaFields(null)).toStrictEqual([]);
});
