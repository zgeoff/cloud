import { expect, test } from 'bun:test';
import { buildStubConcurrencyGroup } from './build-stub-concurrency-group.ts';

test('it starts the first holder at once', () => {
  const group = buildStubConcurrencyGroup<string>('single');

  expect(group.join('first')).toStrictEqual({ started: true, cancelled: [] });
});

test('it starts a waiting holder when the running one finishes', () => {
  const group = buildStubConcurrencyGroup<string>('single');

  group.join('first');

  const joined = group.join('second');

  expect(joined).toStrictEqual({ started: false, cancelled: [] });
  expect(group.finish()).toBe('second');
});

test('it starts the next holder at once after the group empties', () => {
  const group = buildStubConcurrencyGroup<string>('single');

  group.join('first');

  const next = group.finish();

  expect(next).toBeUndefined();
  expect(group.join('second')).toStrictEqual({ started: true, cancelled: [] });
});

test('it cancels the waiting holder for a newcomer under queue: single', () => {
  const group = buildStubConcurrencyGroup<string>('single');

  group.join('first');
  group.join('second');

  const joined = group.join('third');

  expect(joined).toStrictEqual({ started: false, cancelled: ['second'] });
  expect(group.finish()).toBe('third');
});

test('it keeps every waiting holder under queue: max, and starts them in the order they joined', () => {
  const group = buildStubConcurrencyGroup<string>('max');

  group.join('first');
  group.join('second');

  const joined = group.join('third');

  expect(joined).toStrictEqual({ started: false, cancelled: [] });

  expect([group.finish(), group.finish(), group.finish()]).toStrictEqual([
    'second',
    'third',
    undefined,
  ]);
});

test('it cancels a newcomer under queue: max once 100 holders wait', () => {
  const group = buildStubConcurrencyGroup<number>('max');

  Array.from({ length: 101 }, (_unused, index) => group.join(index));

  expect(group.join(101)).toStrictEqual({ started: false, cancelled: [101] });
});
