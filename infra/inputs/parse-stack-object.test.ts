import { expect, test } from 'bun:test';
import { z } from 'zod';
import { parseStackObject } from './parse-stack-object.ts';

test('it returns the parsed object when it fits the schema', () => {
  const schema = z.object({ image: z.string(), hostname: z.string() });

  expect(
    parseStackObject(
      'files',
      { image: 'ghcr.io/acme/files:1.0.0', hostname: 'files.example.test' },
      schema,
    ),
  ).toStrictEqual({ image: 'ghcr.io/acme/files:1.0.0', hostname: 'files.example.test' });
});

test('it throws naming the stack config key and the field of each issue', () => {
  const schema = z.object({ image: z.string(), hostname: z.string() });

  expect(() => parseStackObject('files', { image: 42 }, schema)).toThrowWithMessage(
    Error,
    'stack config "files.image" Invalid input: expected string, received number\nstack config "files.hostname" Invalid input: expected string, received undefined',
  );
});

test('it throws naming the stack config key alone for a value that is not an object', () => {
  expect(() =>
    parseStackObject('files', 'files.example.test', z.object({ hostname: z.string() })),
  ).toThrowWithMessage(
    Error,
    'stack config "files" Invalid input: expected object, received string',
  );
});
