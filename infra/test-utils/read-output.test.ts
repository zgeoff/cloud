import { expect, test } from 'bun:test';
import { all, output, secret } from '@pulumi/pulumi';
import { readOutput } from './read-output.ts';

test('it reads the value of a plain output', () => {
  expect(readOutput(output('geoffcloud'))).resolves.toBe('geoffcloud');
});

test('it reads the value of a secret output', () => {
  const token = secret('a'.repeat(32));

  expect(readOutput(token)).resolves.toBe('a'.repeat(32));
});

test('it reads the value of an output built from others', () => {
  const service = all([output('atc'), output(8414)]);

  expect(readOutput(service)).resolves.toStrictEqual(['atc', 8414]);
});
