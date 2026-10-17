import { expect, test } from 'bun:test';
import { parsePinTable } from './parse-pin-table.ts';

test('it parses each entry and its string values', () => {
  expect(
    parsePinTable('{"demo":{"version":"1.4.2","sum":"abc"},"other":{"version":"0.2.0"}}\n'),
  ).toStrictEqual({ demo: { version: '1.4.2', sum: 'abc' }, other: { version: '0.2.0' } });
});

test('it keeps a __proto__ entry and field as their own keys', () => {
  const table = parsePinTable('{"__proto__":{"__proto__":"1.0.0"}}');

  if (table instanceof Error) {
    throw table;
  }

  expect(Object.keys(table)).toStrictEqual(['__proto__']);
  expect(Object.keys(table['__proto__'] ?? {})).toStrictEqual(['__proto__']);
});

test.each([['[]'], ['"demo"'], ['null'], ['{"demo":']])(
  'it refuses %s as no JSON object',
  (text: string) => {
    expect(parsePinTable(text)).toStrictEqual(
      new Error('scripts/release/release-pins.json holds no JSON object'),
    );
  },
);

test.each([
  ['{"demo":{"version":"1.4.2"},"other":"0.2.0"}'],
  ['{"demo":{"version":"1.4.2"},"other":["0.2.0"]}'],
  ['{"demo":{"version":"1.4.2"},"other":{"version":2}}'],
])('it refuses %s, whose other entry is no object of strings', (text: string) => {
  expect(parsePinTable(text)).toStrictEqual(
    new Error('scripts/release/release-pins.json holds other as no object of strings'),
  );
});
