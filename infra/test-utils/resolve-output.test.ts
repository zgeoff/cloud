import { expect, test } from 'bun:test';
import { all, output, secret, unknown } from '@pulumi/pulumi';
import { resolveOutput } from './resolve-output.ts';

test('it reads the value of a plain output', () => {
  expect(resolveOutput(output('geoffcloud'))).resolves.toBe('geoffcloud');
});

test('it reads the value of a secret output', () => {
  const token = secret('a'.repeat(32));

  expect(resolveOutput(token)).resolves.toBe('a'.repeat(32));
});

test('it reads the value of an output built from others', () => {
  const service = all([output('atc'), output(8414)]);

  expect(resolveOutput(service)).resolves.toStrictEqual(['atc', 8414]);
});

// An unknown Output skips apply's callback, so its promise never settles. A control
// resolved through a known Output takes the same steps, so it wins the race only when the
// unknown one has not settled by then; the next test shows a known Output beats it.
test('it leaves the value of an unknown output, as in a preview, unsettled', () => {
  const pending = resolveOutput(output(unknown));

  const control = (async () => {
    await resolveOutput(output('control'));

    return 'unsettled';
  })();

  expect(Promise.race([pending, control])).resolves.toBe('unsettled');
});

test('it settles a known output before a control resolved through another', () => {
  const settled = resolveOutput(output('known'));

  const control = (async () => {
    await resolveOutput(output('control'));

    return 'unsettled';
  })();

  expect(Promise.race([settled, control])).resolves.toBe('known');
});
