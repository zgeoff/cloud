import { expect, test } from 'bun:test';
import { findRecord } from './find-record.ts';

test('it finds the first record whose field holds the value', () => {
  const list = [
    { name: 'kimi', kind: 'custom' },
    { name: 'glm', kind: 'custom' },
    { name: 'glm', kind: 'other' },
  ];

  expect(findRecord(list, 'name', 'glm')).toBe(list[1]);
});

test.each([
  ['a list without the value', [{ name: 'kimi' }]],
  ['a list of records without the field', [{ title: 'glm' }]],
  ['an object that is not a list', { name: 'glm' }],
  ['null', null],
])('it finds nothing in %s', (_label: string, list: unknown) => {
  expect(findRecord(list, 'name', 'glm')).toBeUndefined();
});
