import { expect, test } from 'bun:test';
import { ExitError } from './exit-error.ts';
import { runOrExit } from './run-or-exit.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it returns the result of a command that succeeds and passes its stderr through', async () => {
  const stub = buildStubRunner(() => ({ stdout: 'listing\n', stderr: 'a warning\n' }));
  const printed: string[] = [];

  const result = await runOrExit(
    { run: stub.run, printOut: () => {}, printErr: (text) => printed.push(text) },
    ['ls'],
  );

  expect(result.stdout.toString()).toBe('listing\n');
  expect(printed).toStrictEqual(['a warning\n']);
});

test('it stops with the exit code of a command that fails, after its stderr', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 4, stderr: 'no such vault\n' }));
  const printed: string[] = [];

  const run = runOrExit(
    { run: stub.run, printOut: () => {}, printErr: (text) => printed.push(text) },
    ['op', 'vault', 'get', 'missing'],
  );

  expect(run).rejects.toStrictEqual(new ExitError(4, ''));

  await run.catch(() => {});

  expect(printed).toStrictEqual(['no such vault\n']);
});

test('it stops with 124 when a command times out, as timeout exits', () => {
  const stub = buildStubRunner(() => ({ exitCode: 143, timedOut: true }));

  expect(
    runOrExit(
      { run: stub.run, printOut: () => {}, printErr: () => {} },
      ['imp', 'image', 'build'],
      {
        timeoutMs: 1000,
      },
    ),
  ).rejects.toStrictEqual(new ExitError(124, 'imp timed out'));
});

test('it hands the stdin and the timeout to the runner', async () => {
  const stub = buildStubRunner(() => ({}));

  await runOrExit({ run: stub.run, printOut: () => {}, printErr: () => {} }, ['cat'], {
    stdin: Buffer.from('value\n'),
    timeoutMs: 5000,
  });

  expect(stub.calls).toStrictEqual([
    {
      argv: ['cat'],
      stdin: 'value\n',
      options: { stdin: Buffer.from('value\n'), timeoutMs: 5000 },
    },
  ]);
});
