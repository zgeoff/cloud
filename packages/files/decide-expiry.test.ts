import { expect, test } from 'bun:test';
import { decideExpiry } from './decide-expiry.ts';

test.each([
  ['7d', 'agent', '2026-05-08T12:00:00.000Z'],
  ['30d', 'agent', '2026-05-31T12:00:00.000Z'],
  ['7d', 'owner', '2026-05-08T12:00:00.000Z'],
  ['2026-05-20', 'agent', '2026-05-20T00:00:00.000Z'],
  ['2026-05-31T12:00:00Z', 'agent', '2026-05-31T12:00:00.000Z'],
  ['2026-05-02T09:30:00+10:00', 'agent', '2026-05-01T23:30:00.000Z'],
  ['2027-01-01', 'owner', '2027-01-01T00:00:00.000Z'],
] as const)('it lets %s from the %s token expire at %s', (expires, role, expected) => {
  expect(decideExpiry({ expires, role, now: new Date('2026-05-01T12:00:00Z') })).toStrictEqual({
    outcome: 'allowed',
    expiresAt: new Date(expected),
  });
});

test('it lets the owner token keep a file forever', () => {
  expect(
    decideExpiry({ expires: 'never', role: 'owner', now: new Date('2026-05-01T12:00:00Z') }),
  ).toStrictEqual({ outcome: 'allowed', expiresAt: null });
});

test('it refuses never from the agent token', () => {
  expect(
    decideExpiry({ expires: 'never', role: 'agent', now: new Date('2026-05-01T12:00:00Z') }),
  ).toStrictEqual({ outcome: 'forbidden', reason: 'the agent token cannot keep a file forever' });
});

test.each([['2026-06-01'], ['2026-05-31T12:00:00.001Z'], ['2027-01-01']])(
  'it refuses %s from the agent token, more than 30 days away',
  (expires) => {
    expect(
      decideExpiry({ expires, role: 'agent', now: new Date('2026-05-01T12:00:00Z') }),
    ).toStrictEqual({
      outcome: 'forbidden',
      reason: 'the agent token keeps a file 30 days at most',
    });
  },
);

test.each([['2026-05-01T12:00:00Z'], ['2026-04-30'], ['2020-01-01T00:00:00Z']])(
  'it refuses %s, which is not in the future',
  (expires) => {
    expect(
      decideExpiry({ expires, role: 'owner', now: new Date('2026-05-01T12:00:00Z') }),
    ).toStrictEqual({ outcome: 'invalid', reason: 'expires must be in the future' });
  },
);

test.each([['1d'], ['7'], ['forever'], ['2026-13-01'], ['2026-05-31T12:00:00'], ['']])(
  'it refuses %p, which names no expiry',
  (expires) => {
    expect(
      decideExpiry({ expires, role: 'owner', now: new Date('2026-05-01T12:00:00Z') }),
    ).toStrictEqual({
      outcome: 'invalid',
      reason: 'expires must be 7d, 30d, never, a date, or a date and time with its offset',
    });
  },
);
