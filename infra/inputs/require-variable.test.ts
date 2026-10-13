import { expect, test } from 'bun:test';
import { requireVariable } from './require-variable.ts';

test('it returns a set value as given', () => {
  expect(
    requireVariable(
      { NIXIE_AGE_HOST_KEY: 'AGE-SECRET-KEY-1\n' },
      'NIXIE_AGE_HOST_KEY',
      'nixie needs it',
    ),
  ).toBe('AGE-SECRET-KEY-1\n');
});

test('it throws naming the variable and the need when the variable is unset', () => {
  expect(() => requireVariable({}, 'NIXIE_AGE_HOST_KEY', 'nixie needs it')).toThrowWithMessage(
    Error,
    'NIXIE_AGE_HOST_KEY is unset; nixie needs it',
  );
});

test('it throws without echoing it when the value holds only whitespace', () => {
  expect(() =>
    requireVariable({ NIXIE_AGE_HOST_KEY: ' \t\n' }, 'NIXIE_AGE_HOST_KEY', 'nixie needs it'),
  ).toThrowWithMessage(Error, 'NIXIE_AGE_HOST_KEY is blank; nixie needs it');
});
