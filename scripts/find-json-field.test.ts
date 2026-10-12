import { expect, test } from 'bun:test';
import { findJSONField } from './find-json-field.ts';

test('it finds a field of an object', () => {
  expect(findJSONField({ json: { code: 'UNAUTHORIZED' } }, 'json')).toStrictEqual({
    code: 'UNAUTHORIZED',
  });
});

test.each([
  ['an object without the field', { meta: [] }],
  ['null', null],
  ['a string', 'the client header is missing'],
  ['nothing', undefined],
])('it finds nothing in %s', (_label: string, value: unknown) => {
  expect(findJSONField(value, 'json')).toBeUndefined();
});
