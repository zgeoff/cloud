import { expect, test } from 'bun:test';
import { ExitError } from './exit-error.ts';
import { withExitCode } from './with-exit-code.ts';

test('it returns the exit code the body returns', async () => {
  const printed: string[] = [];

  const exitCode = await withExitCode(
    (text) => printed.push(text),
    () => Promise.resolve(0),
  );

  expect(exitCode).toBe(0);
  expect(printed).toStrictEqual([]);
});

test('it prints an ExitError’s message and returns its exit code', async () => {
  const printed: string[] = [];

  const exitCode = await withExitCode(
    (text) => printed.push(text),
    () => Promise.reject(new ExitError(3, 'the vault is missing')),
  );

  expect(exitCode).toBe(3);
  expect(printed).toStrictEqual(['the vault is missing\n']);
});

test('it prints nothing for an ExitError whose tool has already said why', async () => {
  const printed: string[] = [];

  const exitCode = await withExitCode(
    (text) => printed.push(text),
    () => Promise.reject(new ExitError(255, '')),
  );

  expect(exitCode).toBe(255);
  expect(printed).toStrictEqual([]);
});

test('it lets any other error propagate', () => {
  expect(
    withExitCode(
      () => {},
      () => Promise.reject(new TypeError('a bug')),
    ),
  ).rejects.toThrowWithMessage(TypeError, 'a bug');
});
