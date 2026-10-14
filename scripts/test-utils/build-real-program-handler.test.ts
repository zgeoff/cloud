import { expect, test } from 'bun:test';
import { buildRealProgramHandler } from './build-real-program-handler.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it runs a named program for real, with the call’s stdin', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['tr']));

  const result = await stub.run(['tr', 'a-z', 'A-Z'], { stdin: Buffer.from('loud\n') });

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('LOUD\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it leaves any other program to the next handler', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['tr']));

  const result = await stub.run(['ssh', 'root@geoffcloud', 'true']);

  expect(result.exitCode).toBe(97);
});
