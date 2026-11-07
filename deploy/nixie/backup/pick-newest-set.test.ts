import { expect, test } from 'bun:test';
import { pickNewestSet } from './pick-newest-set.ts';

test.each([
  [
    'set-10 over set-2, by number',
    '[{"id":"a1","tags":["set-2","kind-scheduled"]},{"id":"b2","tags":["set-10","kind-scheduled"]}]',
    'set-10',
  ],
  [
    'a set read from tags alone, never from the host or paths',
    '[{"id":"a1","hostname":"set-99","paths":["/set-99"]},{"id":"b2","tags":["set-1"]}]',
    'set-1',
  ],
  [
    'no set for snapshots that carry no set tag',
    '[{"id":"a1","tags":["nixie"]},{"id":"b2"}]',
    undefined,
  ],
  ['no set for an empty list', '[]', undefined],
])('it picks %s', (_case: string, text: string, picked: string | undefined) => {
  expect(pickNewestSet(text)).toBe(picked);
});

test.each([
  ['an object in place of the list', '{"message_type":"summary"}'],
  ['a snapshot with no id', '[{"tags":["set-1"]}]'],
  ['a snapshot whose tags are not strings', '[{"id":"a1","tags":[1]}]'],
  ['a snapshot whose tags are not a list', '[{"id":"a1","tags":"set-1"}]'],
  ['text that is not JSON', 'Fatal: unable to open config file'],
])('it refuses %s as no snapshot list', (_case: string, text: string) => {
  expect(pickNewestSet(text)).toStrictEqual(new Error('restic printed no snapshot list'));
});
