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

test("it never sleeps a contract run's imp, which the wake proxy never sees in use", () => {
  expect(
    planIdleSleeps(
      [
        {
          name: 'pv-sdk-0123456789abcdef',
          state: 'running',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual([]);
});

test('it leaves a preview that already sleeps alone', () => {
  expect(
    planIdleSleeps(
      [
        {
          name: 'pv-0a1b2c3d-17',
          state: 'sleeping',
          lastActiveAt: new Date('2026-10-15T07:00:00Z'),
        },
      ],
      1_800_000,
      new Date('2026-10-15T09:00:00Z'),
    ),
  ).toStrictEqual([]);
});
