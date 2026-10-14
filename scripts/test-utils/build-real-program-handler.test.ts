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

test('it runs a call that sets no env with the handler’s env', async () => {
  const stub = buildStubRunner(
    buildRealProgramHandler(['sh'], { MARK: 'handler', PATH: '/usr/bin:/bin' }),
  );

  const result = await stub.run(['sh', '-c', 'printf %s "$MARK"']);

  expect(result.stdout.toString()).toBe('handler');
});

test('it keeps the env a call sets over the handler’s', async () => {
  const stub = buildStubRunner(
    buildRealProgramHandler(['sh'], { MARK: 'handler', PATH: '/usr/bin:/bin' }),
  );

  const result = await stub.run(['sh', '-c', 'printf %s "$MARK"'], {
    env: { MARK: 'call', PATH: '/usr/bin:/bin' },
  });

  expect(result.stdout.toString()).toBe('call');
});

test('it leaves any other program to the next handler', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['tr']));

  const result = await stub.run(['ssh', 'root@geoffcloud', 'true']);

  expect(result.exitCode).toBe(97);
});
