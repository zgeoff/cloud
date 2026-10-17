import { expect, test } from 'bun:test';
import { planSlotEvictions } from './plan-slot-evictions.ts';

test('it sleeps the running preview when one slot must take the opening one', () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:00:00Z'),
        },
      ],
      1,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual(['pv-0a1b2c3d-17']);
});

test('it sleeps the least recently active previews first', () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:30:00Z'),
        },
        {
          name: 'pv-0a1b2c3d-19',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:10:00Z'),
        },
        {
          name: 'pv-0a1b2c3d-20',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      2,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual(['pv-0a1b2c3d-20', 'pv-0a1b2c3d-19']);
});

test('it never sleeps the opening preview', () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-0a1b2c3d-18',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      1,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual([]);
});

test('it counts only running previews against the slots', () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'sleeping',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
        {
          name: 'pv-0a1b2c3d-19',
          state: 'stopped',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      1,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual([]);
});

test("it never sleeps a contract run's imp, though it holds a slot", () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-sdk-0123456789abcdef',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
        {
          name: 'pv-0a1b2c3d-17',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:00:00Z'),
        },
      ],
      2,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual(['pv-0a1b2c3d-17']);
});

test("it sleeps nothing when a contract run's imp holds the only slot", () => {
  expect(
    planSlotEvictions(
      [
        {
          name: 'pv-sdk-0123456789abcdef',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      1,
      'pv-0a1b2c3d-18',
    ),
  ).toStrictEqual([]);
});
