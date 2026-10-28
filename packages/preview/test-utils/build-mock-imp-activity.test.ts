import { expect, test } from 'bun:test';
import { buildMockImpActivity } from './build-mock-imp-activity.ts';

test('it builds a default imp activity', () => {
  expect(buildMockImpActivity()).toStrictEqual({
    name: expect.toSatisfy((name: string) => /^pv-[\da-f]{8}-\d+$/u.test(name)),
    state: 'running',
    lastActiveAt: expect.toBeValidDate(),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockImpActivity({
      name: 'pv-sdk-0123456789abcdef',
      state: 'sleeping',
      lastActiveAt: new Date('2026-10-15T08:00:00Z'),
    }),
  ).toStrictEqual({
    name: 'pv-sdk-0123456789abcdef',
    state: 'sleeping',
    lastActiveAt: new Date('2026-10-15T08:00:00Z'),
  });
});
