import { expect, test } from 'bun:test';
import { planContractEvictions } from './plan-contract-evictions.ts';
import { buildMockImpActivity } from './test-utils/build-mock-imp-activity.ts';

test('it sleeps nothing when a slot is free', () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-17',
      state: 'sleeping',
      lastActiveAt: new Date('2026-10-15T08:00:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 1,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toStrictEqual([]);
});

test('it sleeps the preview in the slot once it has gone unused for the idle time', () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-17',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:55:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 1,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toStrictEqual(['pv-0a1b2c3d-17']);
});

test('it waits rather than sleep a preview used within the idle time', () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-17',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:55:01Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 1,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toBeNull();
});

test("it waits rather than sleep another run's imp, however long ago it was used", () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-sdk-fedcba9876543210',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T07:00:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 1,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toBeNull();
});

test("it leaves the run's own imp out of the slot count", () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-sdk-0123456789abcdef',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:59:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 1,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toStrictEqual([]);
});

test('it sleeps the least recently used idle previews, as many as the run needs', () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-17',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:30:00Z'),
    }),
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-18',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:58:00Z'),
    }),
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-19',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:10:00Z'),
    }),
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-20',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:40:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 3,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toStrictEqual(['pv-0a1b2c3d-19', 'pv-0a1b2c3d-17']);
});

test('it waits when too few previews are idle to free a slot', () => {
  const imps = [
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-17',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:30:00Z'),
    }),
    buildMockImpActivity({
      name: 'pv-sdk-fedcba9876543210',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:00:00Z'),
    }),
    buildMockImpActivity({
      name: 'pv-0a1b2c3d-18',
      state: 'running',
      lastActiveAt: new Date('2026-10-15T08:58:00Z'),
    }),
  ];

  expect(
    planContractEvictions(imps, 'pv-sdk-0123456789abcdef', {
      slots: 2,
      idleMs: 300_000,
      now: new Date('2026-10-15T09:00:00Z'),
    }),
  ).toBeNull();
});
