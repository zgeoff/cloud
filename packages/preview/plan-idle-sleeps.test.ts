import { expect, test } from 'bun:test';
import { planIdleSleeps } from './plan-idle-sleeps.ts';

test('it sleeps a running preview unused for the idle timeout', () => {
  expect(
    planIdleSleeps(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:30:00Z'),
        },
      ],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual(['pv-0a1b2c3d-17']);
});

test('it keeps a running preview used within the idle timeout', () => {
  expect(
    planIdleSleeps(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T08:30:01Z'),
        },
      ],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual([]);
});

test('it counts a running preview with no recorded use as idle', () => {
  expect(
    planIdleSleeps(
      [{ name: 'pv-0a1b2c3d-17', state: 'running', lastActiveAt: null }],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual(['pv-0a1b2c3d-17']);
});

test('it leaves a preview that already sleeps alone', () => {
  expect(
    planIdleSleeps(
      [{ name: 'pv-0a1b2c3d-17', state: 'sleeping', lastActiveAt: null }],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual([]);
});
