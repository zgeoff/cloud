import { expect, test } from 'bun:test';
import { pickSpendAdmission } from './pick-spend-admission.ts';

test.each([['waiting'], ['booting'], ['ready'], ['failed']] as const)(
  'it admits a call on the route of a %s preview',
  (phase) => {
    expect(
      pickSpendAdmission(
        '/pv-0a1b2c3d-7/v1/messages',
        { imp: 'pv-0a1b2c3d-7', path: '/v1/messages' },
        phase,
      ),
    ).toStrictEqual({ admitted: true, imp: 'pv-0a1b2c3d-7' });
  },
);

test('it refuses a call on the route of an ended preview', () => {
  expect(
    pickSpendAdmission(
      '/pv-0a1b2c3d-7/v1/messages',
      { imp: 'pv-0a1b2c3d-7', path: '/v1/messages' },
      'ended',
    ),
  ).toStrictEqual({
    admitted: false,
    refusal: { kind: 'no-preview', pathname: '/pv-0a1b2c3d-7/v1/messages' },
  });
});

test('it refuses a call on a route that no preview holds', () => {
  expect(
    pickSpendAdmission(
      '/pv-0a1b2c3d-8/v1/messages',
      { imp: 'pv-0a1b2c3d-8', path: '/v1/messages' },
      null,
    ),
  ).toStrictEqual({
    admitted: false,
    refusal: { kind: 'no-preview', pathname: '/pv-0a1b2c3d-8/v1/messages' },
  });
});

test('it refuses a call on a path that holds no route', () => {
  expect(pickSpendAdmission('//v1/messages', null, null)).toStrictEqual({
    admitted: false,
    refusal: { kind: 'no-preview', pathname: '//v1/messages' },
  });
});
