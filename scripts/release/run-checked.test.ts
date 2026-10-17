import { expect, test } from 'bun:test';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { runChecked } from './run-checked.ts';

test('it gives the stdout of a program that exits 0', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['sh']));

  const result = await runChecked(stub.run, ['sh', '-c', 'echo pinned; echo noise >&2']);

  expect(result).toBe('pinned\n');
});

test('it gives the trimmed stderr of a failed program as the error', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['sh']));

  const result = await runChecked(stub.run, ['sh', '-c', 'echo "  no such release  " >&2; exit 1']);

  expect(result).toStrictEqual(new Error('no such release'));
});

test('it names the argv and exit code of a failed program that printed no stderr', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['sh']));

  const result = await runChecked(stub.run, ['sh', '-c', 'exit 3']);

  expect(result).toStrictEqual(new Error('sh -c exit 3 exited 3'));
});

test('it hands the options to the program', async () => {
  const stub = buildStubRunner(buildRealProgramHandler(['cat']));

  const result = await runChecked(stub.run, ['cat'], { stdin: Buffer.from('the body\n') });

  expect(result).toBe('the body\n');
});
